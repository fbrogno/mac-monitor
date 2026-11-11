#!/bin/zsh
# Re-renders all README images from the real SwiftUI views: German into docs/images, English into
# docs/images/en. The translations are only loaded by the xcodebuild bundle (a plain SwiftPM build
# shows German only), so this builds the app like scripts/build-app.sh (unsigned) and runs its binary.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen fehlt (brew install xcodegen)." >&2; exit 1; }
xcodegen generate --quiet
xcodebuild -project MacMonitor.xcodeproj -scheme MacMonitor -configuration Release \
  -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -quiet build
binary=build/DerivedData/Build/Products/Release/MacMonitor.app/Contents/MacOS/MacMonitor
$binary --render-docs docs/images --lang de
$binary --render-docs docs/images/en --lang en
