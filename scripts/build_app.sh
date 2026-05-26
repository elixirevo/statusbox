#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="StatusBox"
APP_DIR="$ROOT_DIR/dist/StatusBox.app"
BUILD_CONFIG="${BUILD_CONFIG:-release}"

cd "$ROOT_DIR"
swift build -c "$BUILD_CONFIG"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp ".build/$BUILD_CONFIG/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
find "$ROOT_DIR/Resources" -maxdepth 1 -type f ! -name "Info.plist" -exec cp {} "$APP_DIR/Contents/Resources/" \;

chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
codesign \
  --force \
  --sign - \
  --identifier "com.elixirevo.StatusBox" \
  --requirements '=designated => identifier "com.elixirevo.StatusBox"' \
  "$APP_DIR"

echo "Built $APP_DIR"
