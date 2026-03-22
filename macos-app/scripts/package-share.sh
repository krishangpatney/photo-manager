#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Photo Transfer Manager.app"
DIST_DIR="$ROOT_DIR/dist"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ZIP_PATH="$DIST_DIR/photo-transfer-manager-${VERSION}-macos.zip"

VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" "$ROOT_DIR/scripts/build-app.sh"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"

echo "Creating shareable zip..."
ditto -c -k --sequesterRsrc --keepParent "$ROOT_DIR/.build/share/$APP_NAME" "$ZIP_PATH"

echo "Shareable zip ready:"
echo "  $ZIP_PATH"
