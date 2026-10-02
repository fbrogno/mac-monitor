#!/bin/zsh
# Re-renders all README images in docs/images from the real SwiftUI views.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product MacMonitor >/dev/null
.build/release/MacMonitor --render-docs docs/images
