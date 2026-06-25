#!/bin/bash
# Regenerate AppIcon.icns from make-icon.swift. Run after changing the icon art.
set -euo pipefail
cd "$(dirname "$0")"

echo "▸ Rendering 1024px master…"
swift make-icon.swift

ICONSET="AppIcon.iconset"
rm -rf "$ICONSET"; mkdir "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s"       icon-1024.png --out "$ICONSET/icon_${s}x${s}.png"     >/dev/null
    sips -z "$((s*2))" "$((s*2))" icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$ICONSET" icon-1024.png
echo "✓ AppIcon.icns"
