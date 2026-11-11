#!/bin/zsh
# Builds, signs (Developer ID), notarizes and packs MacMonitor, then writes the Sparkle appcast.
#
#   scripts/release.sh [--skip-notarize]
#
# Output: build/MacMonitor-<version>.dmg and build/appcast.xml
#
# Notarization login (one of):
#   NOTARY_PROFILE                              keychain profile (xcrun notarytool store-credentials)
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH     App Store Connect API key (CI)
# Appcast signing:
#   SPARKLE_PRIVATE_KEY                         EdDSA private key, piped via stdin, never written to disk
#   SPARKLE_USE_KEYCHAIN=1                      alternatively use the key in the local keychain
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
  if [[ -z ${NOTARY_PROFILE:-} && ( -z ${ASC_KEY_ID:-} || -z ${ASC_ISSUER_ID:-} || -z ${ASC_KEY_PATH:-} ) ]]; then
    echo "Abbruch: Für die Notarisierung fehlt NOTARY_PROFILE oder ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_PATH." >&2
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
              "$app"/Contents/Frameworks/*.framework/Versions/[A-Z]/Autoupdate(N); do
  check_signature "$nested"
done
echo "Signatur geprüft: $app"

# --- dmg ---------------------------------------------------------------------------------
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/MacMonitor.app"
ln -s /Applications "$stage/Programme"
rm -f "$dmg"
hdiutil create -volname "MacMonitor" -srcfolder "$stage" -fs APFS -format ULFO -ov "$dmg" >/dev/null
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$dmg"
codesign --verify --strict "$dmg"
echo "DMG: $dmg"

# --- notarize ----------------------------------------------------------------------------
if (( skip_notarize )); then
  echo "Notarisierung übersprungen (--skip-notarize)."
else
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    notary_auth=(--keychain-profile "$NOTARY_PROFILE")
  else
    notary_auth=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
  fi
  xcrun notarytool submit "$dmg" "${notary_auth[@]}" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl -a -t open --context context:primary-signature -v "$dmg"
  echo "Notarisiert und geheftet: $dmg"
fi

# --- appcast -----------------------------------------------------------------------------
if [[ -z ${SPARKLE_PRIVATE_KEY:-} && ${SPARKLE_USE_KEYCHAIN:-} != 1 ]]; then
  echo "Appcast übersprungen (kein SPARKLE_PRIVATE_KEY)."
  exit 0
fi
sparkle_bin=${SPARKLE_BIN:-build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin}
[[ -x $sparkle_bin/generate_appcast ]] || { echo "generate_appcast fehlt in $sparkle_bin (SPARKLE_BIN setzen)." >&2; exit 1; }

feed=$(mktemp -d)
trap 'rm -rf "$stage" "$feed"' EXIT
cp "$dmg" "$feed/"
base=https://github.com/fbrogno/mac-monitor/releases
appcast_args=(--download-url-prefix "$base/download/v$version/" --full-release-notes-url "$base/tag/v$version")
if [[ -n ${SPARKLE_PRIVATE_KEY:-} ]]; then
  print -rn -- "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/generate_appcast" --ed-key-file - "${appcast_args[@]}" "$feed" 2>&1 | tail -n 5
else
  "$sparkle_bin/generate_appcast" "${appcast_args[@]}" "$feed" 2>&1 | tail -n 5
fi
cp "$feed/appcast.xml" build/appcast.xml
grep -q "sparkle:edSignature" build/appcast.xml || { echo "Appcast ohne Signatur." >&2; exit 1; }
grep -q "$base/download/v$version/MacMonitor-$version.dmg" build/appcast.xml || { echo "Appcast zeigt auf die falsche URL." >&2; exit 1; }
echo "Appcast: build/appcast.xml"
