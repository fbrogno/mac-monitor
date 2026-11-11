#!/bin/zsh
# Builds build/MacMonitor.app (Release) from project.yml via XcodeGen + xcodebuild.
#
# Signing is done here, not by Xcode, so Sparkle's nested code is signed from the inside out
# (XPC services, Updater.app, Autoupdate, framework, app) without --deep.
#
# SIGN_IDENTITY  "-" = ad-hoc, otherwise a keychain identity (name or SHA-1).
#                Default: "Developer ID Application", else "Apple Development", else ad-hoc.
#                Desktop widgets (app group, sandbox) are only kept for "Developer ID" identities: the
#                group id is <TEAM ID>.com.fbrogno.macmonitor, the team ID is read from the certificate.
#                With ad-hoc or Apple Development signatures the widget extension is removed again.
# VERSION        Marketing version comes from the VERSION file, build number from the commit count.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen fehlt (brew install xcodegen)." >&2; exit 1; }

version=$(<VERSION)
version=${version//[[:space:]]/}
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)

# --- signing identity -------------------------------------------------------------------
identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
pick() { print -r -- "$identities" | awk -v kind="$1" -F'"' '$2 ~ "^" kind {split($1, a, " "); print a[2]; exit}'; }
identity=${SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
  identity=$(pick "Developer ID Application")
  [[ -n $identity ]] || identity=$(pick "Apple Development")
  [[ -n $identity ]] || identity="-"
fi
if [[ $identity == "-" ]]; then
  kind="ad-hoc"
else
  name=$(print -r -- "$identities" | awk -v id="$identity" -F'"' 'index($1, id) {print $2; exit}')
  [[ -n $name ]] || name=$identity
  case $name in
    "Developer ID Application"*) kind="Developer ID" ;;
    "Apple Development"*) kind="Apple Development" ;;
    *) kind=$name ;;
  esac
fi

# --- build ------------------------------------------------------------------------------
xcodegen generate --quiet
xcodebuild -project MacMonitor.xcodeproj -scheme MacMonitor -configuration Release \
  -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  -quiet build

app=build/MacMonitor.app
rm -rf "$app"
ditto build/DerivedData/Build/Products/Release/MacMonitor.app "$app"

# --- widgets: team ID and entitlements ----------------------------------------------------
# App-group id on macOS: "<team identifier>.<group name>", no provisioning profile needed
# (Apple: "Configuring app groups"). The team ID is never stored in the repo: it comes from the
# signing certificate and is put into the entitlement templates here.
with_widgets=0
team=""
if [[ $kind == "Developer ID" ]]; then
  team=$(security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -n 1)
  [[ -n $team ]] || { echo "Team-ID aus dem Zertifikat \"$name\" nicht lesbar." >&2; exit 1; }
  with_widgets=1
fi
ent_dir=build/entitlements
rm -rf "$ent_dir"
if (( with_widgets )); then
  mkdir -p "$ent_dir"
  for t in MacMonitor MacMonitorWidgets; do
    sed "s/__TEAM_ID__/$team/g" "Resources/$t.entitlements.template" > "$ent_dir/$t.entitlements"
    plutil -lint "$ent_dir/$t.entitlements" >/dev/null
  done
else
  rm -rf "$app"/Contents/PlugIns/MacMonitorWidgets.appex
  rmdir "$app"/Contents/PlugIns 2>/dev/null || true
  echo "HINWEIS: Widgets nicht enthalten (Signatur: $kind). Sie brauchen eine Developer-ID-Signatur für die App-Gruppe." >&2
fi

# --- sign, innermost first ---------------------------------------------------------------
sign_args=(--force --sign "$identity")
if [[ $identity == "-" ]]; then
  # Library validation would refuse ad-hoc signed frameworks, so no hardened runtime here.
  sign_args+=(--timestamp=none)
elif [[ $kind == "Developer ID" ]]; then
  sign_args+=(--options runtime --timestamp)
else
  sign_args+=(--options runtime --timestamp=none)
fi
sign() { codesign "${sign_args[@]}" --preserve-metadata=entitlements "$@"; }

for fw in "$app"/Contents/Frameworks/*.framework(N); do
  for v in "$fw"/Versions/[A-Z](N); do
    for xpc in "$v"/XPCServices/*.xpc(N); do sign "$xpc"; done
    [[ -d $v/Updater.app ]] && sign "$v/Updater.app"
    [[ -f $v/Autoupdate ]] && sign "$v/Autoupdate"
  done
  sign "$fw"
done
# Extensions: sandbox + app group, signed before the app that contains them.
for plugin in "$app"/Contents/PlugIns/*.appex(N); do
  codesign "${sign_args[@]}" --entitlements "$ent_dir/${plugin:t:r}.entitlements" "$plugin"
done
if (( with_widgets )); then
  codesign "${sign_args[@]}" --entitlements "$ent_dir/MacMonitor.entitlements" "$app"
else
  codesign "${sign_args[@]}" "$app"
fi

codesign --verify --deep --strict "$app"
extra=""
[[ -d $app/Contents/PlugIns/MacMonitorWidgets.appex ]] && extra=", mit Widgets (Team $team)"
echo "Gebaut: $app $version ($build), signiert: $kind$extra"
