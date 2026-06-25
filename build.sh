#!/bin/bash
# Build Nemo and assemble a signed .app bundle (required for mic/speech TCC prompts).
# Set CODESIGN_ID to a "Developer ID Application: …" identity for distributable,
# notarizable builds; otherwise the bundle is ad-hoc signed (fine for local use).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Nemo"
BUNDLE="Nemo.app"
CODESIGN_ID="${CODESIGN_ID:--}"   # "-" = ad-hoc

echo "▸ Compiling (release)…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "✗ Build did not produce $BIN_PATH" >&2
    exit 1
fi

# Ensure the app icon exists (regenerate from source if missing).
if [[ ! -f AppIcon.icns ]]; then
    echo "▸ Generating AppIcon.icns…"
    ./make-icns.sh
fi

echo "▸ Assembling ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

if [[ "$CODESIGN_ID" == "-" ]]; then
    echo "▸ Ad-hoc signing (entitlements, no hardened runtime)…"
    codesign --force --sign - --entitlements Nemo.entitlements "$BUNDLE"
else
    echo "▸ Signing with '$CODESIGN_ID' (hardened runtime)…"
    codesign --force --deep --options runtime --timestamp \
        --sign "$CODESIGN_ID" --entitlements Nemo.entitlements "$BUNDLE"
fi

echo "✓ Built ./$BUNDLE"
echo "  Run locally:   open \"$PWD/$BUNDLE\""
echo "  Install:       ./install.sh        (copies to /Applications)"
echo "  Make DMG:      ./package.sh        (drag-to-install Nemo.dmg)"
