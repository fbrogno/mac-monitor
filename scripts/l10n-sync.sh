#!/bin/zsh
# Brings the string catalogs up to date with the code: new texts appear as keys without an English
# translation, texts no longer in the code are marked "stale". Afterwards translate the new keys
# (state "translated", see README of the catalogs in scripts/check-l10n.sh) and run
# scripts/check-l10n.sh.
#
# xcodebuild extracts every string the compiler sees (String(localized:), Text("…"), LocalizedStringResource,
# App Intents) into .stringsdata files; xcstringstool merges them into the catalogs. No file is
# touched except the .xcstrings of the modules.
#
# Usage: scripts/l10n-sync.sh [--no-build]   (--no-build reuses build/DerivedData)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ${1:-} != "--no-build" ]]; then
  command -v xcodegen >/dev/null || { echo "xcodegen fehlt (brew install xcodegen)." >&2; exit 1; }
  xcodegen generate --quiet
  xcodebuild -project MacMonitor.xcodeproj -scheme MacMonitor -configuration Release \
    -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" SWIFT_EMIT_LOC_STRINGS=YES -quiet build
fi

objects=build/DerivedData/Build/Intermediates.noindex/MacMonitor.build/Release
# module catalog : build directory of the module that contains the code using it
typeset -A map=(
  Sources/MacMonitor/Localizable.xcstrings        MacMonitor.build
  Sources/MacMonitorWidgets/Localizable.xcstrings MacMonitorWidgets.build
  Sources/MonitorCore/Localizable.xcstrings       MonitorCore.build
  Sources/WidgetViews/Localizable.xcstrings       WidgetViews.build
)
for catalog dir in ${(kv)map}; do
  data=($objects/$dir/Objects-normal/arm64/*.stringsdata(N))
  (( $#data )) || { echo "Keine .stringsdata für $dir gefunden." >&2; exit 1; }
  xcrun xcstringstool sync "$catalog" --stringsdata $data
  echo "synchronisiert: $catalog"
done
