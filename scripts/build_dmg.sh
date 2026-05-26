#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="StatusBox"
DISPLAY_NAME="Status Box"
BUNDLE_ID="com.elixirevo.StatusBox"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-13.0}"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
ARCH_LABEL="${ARCH_LABEL:-universal}"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
UNIVERSAL_BUILD_DIR="$ROOT_DIR/.build/universal"
MODULE_CACHE_DIR="$ROOT_DIR/.build/module-cache"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION-$ARCH_LABEL.dmg"
DMG_STAGING_PATH="$DIST_DIR/$APP_NAME-$VERSION-$ARCH_LABEL-staging.dmg"
DMG_MOUNT_DIR="$DIST_DIR/dmg-mount"
DMG_BACKGROUND_DIR=".background"
DMG_BACKGROUND_NAME="background.png"
DMG_BACKGROUND_PATH="$DMG_MOUNT_DIR/$DMG_BACKGROUND_DIR/$DMG_BACKGROUND_NAME"
DMG_WINDOW_WIDTH=660
DMG_WINDOW_HEIGHT=420
DMG_ICON_SIZE=96
APP_ICON_X=180
APPLICATIONS_ICON_X=480
DMG_ICON_Y=220
ARCHS=("arm64" "x86_64")

find_built_executable() {
  local scratch_path="$1"
  local executable
  executable="$(find "$scratch_path" -type f -path "*/$BUILD_CONFIG/$APP_NAME" -perm -111 | head -n 1)"
  if [[ -z "$executable" ]]; then
    echo "Unable to find built executable in $scratch_path" >&2
    exit 1
  fi
  echo "$executable"
}

build_arch() {
  local arch="$1"
  local scratch_path="$ROOT_DIR/.build/$arch"

  echo "Building $APP_NAME $VERSION for $arch..." >&2
  swift build \
    -c "$BUILD_CONFIG" \
    --arch "$arch" \
    --scratch-path "$scratch_path" >&2

  find_built_executable "$scratch_path"
}

rm -rf "$APP_DIR" "$UNIVERSAL_BUILD_DIR" "$DMG_MOUNT_DIR" "$DMG_PATH" "$DMG_STAGING_PATH"
mkdir -p "$DIST_DIR" "$UNIVERSAL_BUILD_DIR" "$MODULE_CACHE_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

built_binaries=()
"$ROOT_DIR/scripts/generate_app_icon.sh"

for arch in "${ARCHS[@]}"; do
  built_binaries+=("$(build_arch "$arch")")
done

echo "Creating universal binary..."
lipo -create "${built_binaries[@]}" -output "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
lipo -info "$APP_DIR/Contents/MacOS/$APP_NAME"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_MACOS_VERSION" "$APP_DIR/Contents/Info.plist"
find "$ROOT_DIR/Resources" -maxdepth 1 -type f ! -name "Info.plist" -exec cp {} "$APP_DIR/Contents/Resources/" \;

codesign \
  --force \
  --sign - \
  --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" \
  "$APP_DIR"

echo "Creating DMG..."
hdiutil create \
  "$DMG_STAGING_PATH" \
  -volname "$DISPLAY_NAME" \
  -size 64m \
  -fs HFS+ \
  -ov

mkdir -p "$DMG_MOUNT_DIR"
DMG_DEVICE=""
cleanup_dmg_mount() {
  if [[ -n "$DMG_DEVICE" ]]; then
    hdiutil detach "$DMG_DEVICE" -quiet || true
  fi
}
trap cleanup_dmg_mount EXIT

DMG_DEVICE="$(hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  -mountpoint "$DMG_MOUNT_DIR" \
  "$DMG_STAGING_PATH" \
  | awk '/Apple_HFS/ { print $1; exit }')"

mkdir -p "$DMG_MOUNT_DIR/$DMG_BACKGROUND_DIR"
swift -module-cache-path "$MODULE_CACHE_DIR" "$ROOT_DIR/scripts/create_dmg_background.swift" "$DMG_BACKGROUND_PATH"
cp -R "$APP_DIR" "$DMG_MOUNT_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_MOUNT_DIR/Applications"

osascript <<OSA
set dmgFolder to POSIX file "$DMG_MOUNT_DIR" as alias
set backgroundImage to POSIX file "$DMG_BACKGROUND_PATH"

tell application "Finder"
  open dmgFolder
  delay 1
  set containerWindow to container window of dmgFolder
  set current view of containerWindow to icon view
  try
    set toolbar visible of containerWindow to false
  end try
  try
    set statusbar visible of containerWindow to false
  end try
  set bounds of containerWindow to {100, 100, 100 + $DMG_WINDOW_WIDTH, 100 + $DMG_WINDOW_HEIGHT}

  set viewOptions to the icon view options of containerWindow
  set arrangement of viewOptions to not arranged
  set icon size of viewOptions to $DMG_ICON_SIZE
  set background picture of viewOptions to backgroundImage

  set position of item "$APP_NAME.app" of dmgFolder to {$APP_ICON_X, $DMG_ICON_Y}
  set position of item "Applications" of dmgFolder to {$APPLICATIONS_ICON_X, $DMG_ICON_Y}
  update dmgFolder without registering applications
  delay 2
  close containerWindow
end tell
OSA

if [[ ! -f "$DMG_MOUNT_DIR/.DS_Store" ]]; then
  echo "Finder did not create $DMG_MOUNT_DIR/.DS_Store; unable to save DMG icon layout." >&2
  exit 1
fi

sync
hdiutil detach "$DMG_DEVICE" -quiet
DMG_DEVICE=""
trap - EXIT

hdiutil convert "$DMG_STAGING_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH"

rm -rf "$DMG_MOUNT_DIR" "$DMG_STAGING_PATH"

echo "Built $APP_DIR"
echo "Built $DMG_PATH"
echo
echo "SHA256:"
shasum -a 256 "$DMG_PATH" | awk '{print $1}'
