#!/bin/zsh
# Builds build/MacMonitor.app (release, signed).
# Signs with the first "Apple Development" identity in the keychain so notifications are
# attributed to a stable identity; falls back to ad-hoc signing if none exists.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product MacMonitor
app=build/MacMonitor.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/MacMonitor "$app/Contents/MacOS/MacMonitor"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

identity=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --options runtime --timestamp=none --sign "${identity:--}" "$app"
[[ -n $identity ]] && kind="Apple Development" || kind="ad-hoc"
echo "Gebaut: $app (signiert: $kind)"
