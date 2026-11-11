#!/bin/zsh
# Builds, signs (Developer ID), notarizes and packs MacMonitor, then writes the Sparkle appcast.
#
#   scripts/release.sh [--skip-notarize]
#
# Output: build/MacMonitor-<version>.dmg and build/appcast.xml
#
# Notarization login (one of):
#   NOTARY_PROFILE                              keychain profile (xcrun notarytool store-credentials)
#   ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (key file) or ASC_KEY_P8_BASE64 (key, base64; CI)
# Appcast signing:
#   SPARKLE_PRIVATE_KEY                         EdDSA private key, piped via stdin, never written to disk
#   SPARKLE_USE_KEYCHAIN=1                      alternatively use the key in the local keychain
# The secrets (ASC_*, SPARKLE_PRIVATE_KEY) are taken out of the environment before xcodebuild and package
# resolution run; the App Store Connect key reaches disk only for notarytool, the Sparkle key is only
# piped into sign_update / generate_appcast.
# Tag check: if RELEASE_TAG (or GITHUB_REF_NAME on a tag build) is set, it must equal v<VERSION>.
set -euo pipefail
cd "$(dirname "$0")/.."

skip_notarize=0
for arg in "$@"; do
  case $arg in
    --skip-notarize) skip_notarize=1 ;;
    *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
  esac
done

version=$(<VERSION)
version=${version//[[:space:]]/}
tag=${RELEASE_TAG:-}
[[ -n $tag || ${GITHUB_REF_TYPE:-} != tag ]] || tag=$GITHUB_REF_NAME
if [[ -n $tag && $tag != "v$version" ]]; then
  echo "Abbruch: Tag $tag passt nicht zur Datei VERSION (erwartet v$version)." >&2
  exit 1
fi

# --- preflight: fail before the slow steps -------------------------------------------------
if (( ! skip_notarize )); then
  if [[ -z ${NOTARY_PROFILE:-} && ( -z ${ASC_KEY_ID:-} || -z ${ASC_ISSUER_ID:-} || ( -z ${ASC_KEY_PATH:-} && -z ${ASC_KEY_P8_BASE64:-} ) ) ]]; then
    echo "Abbruch: Für die Notarisierung fehlt NOTARY_PROFILE oder ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_PATH (oder ASC_KEY_P8_BASE64)." >&2
    exit 1
  fi
  if [[ -z ${SPARKLE_PRIVATE_KEY:-} && ${SPARKLE_USE_KEYCHAIN:-} != 1 ]]; then
    echo "Abbruch: Für den Appcast fehlt SPARKLE_PRIVATE_KEY (oder SPARKLE_USE_KEYCHAIN=1)." >&2
    exit 1
  fi
  if ! grep -Eq '^SPARKLE_PUBLIC_ED_KEY *= *[^ ]+' Config/Sparkle.xcconfig; then
    echo "Abbruch: Config/Sparkle.xcconfig hat keinen öffentlichen Sparkle-Schlüssel (scripts/setup-release-secrets.sh)." >&2
    exit 1
  fi
fi

# --- secrets leave the environment ---------------------------------------------------------
# Everything started from here on (xcodebuild, package resolution, build scripts) must not see them.
typeset _asc_key_id=${ASC_KEY_ID:-} _asc_issuer=${ASC_ISSUER_ID:-} _asc_key_path=${ASC_KEY_PATH:-}
typeset _asc_key_b64=${ASC_KEY_P8_BASE64:-} _sparkle_key=${SPARKLE_PRIVATE_KEY:-}
unset ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH ASC_KEY_P8_BASE64 SPARKLE_PRIVATE_KEY

# --- build + sign ------------------------------------------------------------------------
if [[ -z ${SIGN_IDENTITY:-} ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '$2 ~ /^Developer ID Application/ {split($1, a, " "); print a[2]; exit}')
fi
[[ -n $SIGN_IDENTITY && $SIGN_IDENTITY != "-" ]] || {
  echo "Abbruch: Keine Developer-ID-Application-Identität im Schlüsselbund (oder SIGN_IDENTITY setzen)." >&2
  exit 1
}
export SIGN_IDENTITY
./scripts/build-app.sh

app=build/MacMonitor.app
dmg=build/MacMonitor-$version.dmg

check_signature() {
  local info
  info=$(codesign -dv --verbose=4 "$1" 2>&1)
  print -r -- "$info" | grep -q '^Authority=Developer ID Application' || { echo "Keine Developer-ID-Signatur: $1" >&2; exit 1; }
  print -r -- "$info" | grep -Eq 'flags=0x[0-9a-f]+\(.*runtime' || { echo "Hardened Runtime fehlt: $1" >&2; exit 1; }
  print -r -- "$info" | grep -q '^Timestamp=' || { echo "Zeitstempel fehlt: $1" >&2; exit 1; }
}

codesign --verify --deep --strict --verbose=2 "$app"
check_signature "$app"
for nested in "$app"/Contents/Frameworks/*.framework(N) \
              "$app"/Contents/Frameworks/*.framework/Versions/[A-Z]/XPCServices/*.xpc(N) \
              "$app"/Contents/Frameworks/*.framework/Versions/[A-Z]/Updater.app(N) \
              "$app"/Contents/Frameworks/*.framework/Versions/[A-Z]/Autoupdate(N) \
              "$app"/Contents/PlugIns/*.appex(N); do
  check_signature "$nested"
done
# The widget extension must be there, sandboxed, and share the app group with the app.
appex=$app/Contents/PlugIns/MacMonitorWidgets.appex
[[ -d $appex ]] || { echo "Widget-Erweiterung fehlt im Bundle: $appex" >&2; exit 1; }
for target in "$appex" "$app"; do
  ents=$(codesign -d --entitlements - --xml "$target" 2>/dev/null)
  print -r -- "$ents" | grep -q 'com.apple.security.application-groups' || { echo "App-Gruppe fehlt: $target" >&2; exit 1; }
done
print -r -- "$(codesign -d --entitlements - --xml "$appex" 2>/dev/null)" | grep -q 'com.apple.security.app-sandbox' \
  || { echo "Sandbox fehlt in der Widget-Erweiterung." >&2; exit 1; }
[[ -d $app/Contents/Resources/Metadata.appintents ]] || { echo "Metadata.appintents fehlt im Bundle." >&2; exit 1; }
echo "Signatur geprüft: $app"

# --- sparkle: does the signing key belong to the public key in the app? ---------------------
sparkle_bin=${SPARKLE_BIN:-build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin}
have_sparkle_key=0
if [[ -n $_sparkle_key || ${SPARKLE_USE_KEYCHAIN:-} == 1 ]]; then
  have_sparkle_key=1
  [[ -x $sparkle_bin/sign_update ]] || { echo "sign_update fehlt in $sparkle_bin (SPARKLE_BIN setzen)." >&2; exit 1; }
  app_public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")
  probe_dir=$(mktemp -d)
  print -r -- "MacMonitor Schlüsselprobe $version" > "$probe_dir/probe.txt"
  if [[ -n $_sparkle_key ]]; then
    probe_sig=$(print -rn -- "$_sparkle_key" | "$sparkle_bin/sign_update" --ed-key-file - -p "$probe_dir/probe.txt")
  else
    probe_sig=$("$sparkle_bin/sign_update" -p "$probe_dir/probe.txt")
  fi
  swift scripts/verify-sparkle-key.swift "$app_public_key" "$probe_dir/probe.txt" "$probe_sig" || {
    rm -rf "$probe_dir"
    echo "Abbruch: Der Sparkle-Signierschlüssel passt nicht zum SUPublicEDKey der App. Updates würden sich nicht installieren lassen." >&2
    exit 1
  }
  rm -rf "$probe_dir"
  echo "Sparkle-Schlüssel passt zum öffentlichen Schlüssel der App."
fi

# --- notarization helpers ----------------------------------------------------------------
work=$(mktemp -d)
stage=$(mktemp -d)
asc_key_file=""
feed=""
cleanup() {
  rm -rf "$work" "$stage"
  [[ -z $feed ]] || rm -rf "$feed"
  [[ -z $asc_key_file ]] || rm -f "$asc_key_file"
}
trap cleanup EXIT

notarize() {
  xcrun notarytool submit "$1" "${notary_auth[@]}" --wait
}

if (( ! skip_notarize )); then
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    notary_auth=(--keychain-profile "$NOTARY_PROFILE")
  else
    key_path=$_asc_key_path
    if [[ -z $key_path ]]; then
      # CI: the key reaches disk only now (for notarytool) and is removed on exit.
      asc_key_file=$(mktemp "${TMPDIR:-/tmp}/AuthKey.XXXXXX")
      chmod 600 "$asc_key_file"
      print -rn -- "$_asc_key_b64" | base64 --decode > "$asc_key_file"
      key_path=$asc_key_file
    fi
    notary_auth=(--key "$key_path" --key-id "$_asc_key_id" --issuer "$_asc_issuer")
  fi
fi

# --- app: notarize and staple first, so the DMG carries a stapled app ------------------------
if (( skip_notarize )); then
  echo "Notarisierung übersprungen (--skip-notarize)."
else
  ditto -c -k --keepParent "$app" "$work/MacMonitor-app.zip"
  notarize "$work/MacMonitor-app.zip"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl -a -t exec -vv "$app"
  codesign --verify --deep --strict "$app"
  echo "App notarisiert und geheftet: $app"
fi

# --- dmg ---------------------------------------------------------------------------------
ditto "$app" "$stage/MacMonitor.app"
ln -s /Applications "$stage/Programme"
rm -f "$dmg"
hdiutil create -volname "MacMonitor" -srcfolder "$stage" -fs APFS -format ULFO -ov "$dmg" >/dev/null
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$dmg"
codesign --verify --strict "$dmg"
echo "DMG: $dmg"

if (( ! skip_notarize )); then
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl -a -t open --context context:primary-signature -v "$dmg"
  echo "DMG notarisiert und geheftet: $dmg"
fi

# --- appcast -----------------------------------------------------------------------------
if (( ! have_sparkle_key )); then
  echo "Appcast übersprungen (kein SPARKLE_PRIVATE_KEY)."
  exit 0
fi
[[ -x $sparkle_bin/generate_appcast ]] || { echo "generate_appcast fehlt in $sparkle_bin (SPARKLE_BIN setzen)." >&2; exit 1; }

feed=$(mktemp -d)
cp "$dmg" "$feed/"
base=https://github.com/fbrogno/mac-monitor/releases
appcast_args=(--download-url-prefix "$base/download/v$version/" --full-release-notes-url "$base/tag/v$version")
if [[ -n $_sparkle_key ]]; then
  print -rn -- "$_sparkle_key" | "$sparkle_bin/generate_appcast" --ed-key-file - "${appcast_args[@]}" "$feed" 2>&1 | tail -n 5
else
  "$sparkle_bin/generate_appcast" "${appcast_args[@]}" "$feed" 2>&1 | tail -n 5
fi
cp "$feed/appcast.xml" build/appcast.xml
grep -q "sparkle:edSignature" build/appcast.xml || { echo "Appcast ohne Signatur." >&2; exit 1; }
grep -q "$base/download/v$version/MacMonitor-$version.dmg" build/appcast.xml || { echo "Appcast zeigt auf die falsche URL." >&2; exit 1; }
echo "Appcast: build/appcast.xml"
