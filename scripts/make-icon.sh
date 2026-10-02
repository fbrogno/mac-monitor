#!/bin/zsh
# Renders the icon from AppIconView and packs Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product MacMonitor >/dev/null
tmp=$(mktemp -d)
.build/release/MacMonitor --render-docs "$tmp" >/dev/null

iconset="$tmp/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$tmp/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$tmp/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
rm -rf "$tmp"
echo "Resources/AppIcon.icns aktualisiert"
