#!/bin/bash
# Build Nemo and install it into /Applications.
# A locally built bundle isn't quarantined, so it launches without Gatekeeper
# warnings — the simplest "real install" on your own Mac.
set -euo pipefail
cd "$(dirname "$0")"

DEST="/Applications/Nemo.app"

./build.sh

echo "▸ Installing to ${DEST}…"
if [[ -d "$DEST" ]]; then
    # Quit a running copy so the replace succeeds.
    osascript -e 'tell application "Nemo" to quit' >/dev/null 2>&1 || true
    rm -rf "$DEST"
fi
cp -R Nemo.app "$DEST"

echo "✓ Installed Nemo to /Applications"
echo "  Opening… allow the Microphone and Speech-Recognition prompts, then press Start Listening."
open "$DEST"
