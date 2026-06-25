#!/bin/bash
# Build Nemo and package it as a drag-to-install Nemo.dmg (app + Applications alias).
# Set CODESIGN_ID for a Developer ID signed build before distributing to others.
set -euo pipefail
cd "$(dirname "$0")"

DMG="Nemo.dmg"
VOL="Nemo"
STAGE="$(mktemp -d)/dmg"

./build.sh

echo "▸ Staging DMG contents…"
mkdir -p "$STAGE"
cp -R Nemo.app "$STAGE/Nemo.app"
ln -s /Applications "$STAGE/Applications"

echo "▸ Building ${DMG}…"
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ Built ./$DMG"
echo "  Open it and drag Nemo into Applications."
echo "  Note: unless signed with a Developer ID (CODESIGN_ID), the first launch on"
echo "  another Mac needs: right-click Nemo → Open  (or: xattr -dr com.apple.quarantine /Applications/Nemo.app)."
