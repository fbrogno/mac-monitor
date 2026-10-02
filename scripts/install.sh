#!/bin/zsh
# Builds, installs to /Applications (or ~/Applications) and starts MacMonitor.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
target=/Applications
[[ -w $target ]] || { target=$HOME/Applications; mkdir -p "$target"; }

osascript -e 'tell application id "com.fbrogno.macmonitor" to quit' 2>/dev/null || true
sleep 1
rm -rf "$target/MacMonitor.app"
cp -R build/MacMonitor.app "$target/"
open "$target/MacMonitor.app"
echo "Installiert nach $target/MacMonitor.app und gestartet."
