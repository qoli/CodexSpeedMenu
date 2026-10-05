#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
iconset="$(mktemp -d /tmp/CodexSpeedMenu-icon.XXXXXX)/AppIcon.iconset"
trap 'rm -rf "${iconset:h}"' EXIT
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Assets/AppIcon.icns
