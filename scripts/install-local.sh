#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TokenDock"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

"$ROOT_DIR/scripts/build-app.sh" >/dev/null

osascript -e 'tell application "TokenDock" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "$DEST"
ditto "$APP_DIR" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
open "$DEST"
echo "$DEST"
