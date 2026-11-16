#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p .cache/clang .cache/swiftpm
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFTPM_CUSTOM_CACHE_PATH="$PWD/.cache/swiftpm"
bash scripts/build-icon.sh
SDK_15_4="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -d "$SDK_15_4" ]]; then
    export SDKROOT="$SDK_15_4"
elif [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
    # Current Command Line Tools compiler is compatible with this installed SDK,
    # while the unversioned macOS 27 SDK may belong to a different tool build.
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi
BUILD_DIR="/private/tmp/drivegauge-swift-build"
TARGET_ARCH="arm64"
SPARKLE_ROOT="$(zsh scripts/fetch-sparkle.sh)"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.framework"
[[ -d "$SPARKLE_FRAMEWORK" ]] || { echo "Sparkle.framework не найден" >&2; exit 1; }

swift build --disable-sandbox --scratch-path "$BUILD_DIR" --arch "$TARGET_ARCH" -c release \
    -Xswiftc -F -Xswiftc "$SPARKLE_ROOT" \
    -Xlinker "-F$SPARKLE_ROOT" \
    -Xlinker -framework -Xlinker Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks

APP_DIR="dist/DriveGauge.app"
STAGE_ROOT="/private/tmp/drivegauge-app-stage"
STAGED_APP="$STAGE_ROOT/DriveGauge.app"
BIN_DIR="$STAGED_APP/Contents/MacOS"
RESOURCE_DIR="$STAGED_APP/Contents/Resources"
FRAMEWORK_DIR="$STAGED_APP/Contents/Frameworks"
HELPERS_DIR="$STAGED_APP/Contents/Helpers"

# exFAT stores extended attributes in AppleDouble `._*` files. Signing the
# bundle directly there can make LaunchServices reject an otherwise valid app.
# Assemble and sign on APFS first, then copy the sealed bundle without xattrs.
rm -rf "$STAGE_ROOT"
mkdir -p "$BIN_DIR" "$RESOURCE_DIR" "$FRAMEWORK_DIR" "$HELPERS_DIR"
COPYFILE_DISABLE=1 cp "$BUILD_DIR/release/DriveGauge" "$BIN_DIR/DriveGauge"
COPYFILE_DISABLE=1 cp "$BUILD_DIR/release/DriveGaugeNetworkWorker" "$HELPERS_DIR/DriveGaugeNetworkWorker"
COPYFILE_DISABLE=1 cp "Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
COPYFILE_DISABLE=1 cp "Resources/DriveGaugeIconV2.icns" "$RESOURCE_DIR/DriveGaugeIconV2.icns"
COPYFILE_DISABLE=1 ditto --norsrc "$SPARKLE_FRAMEWORK" "$FRAMEWORK_DIR/Sparkle.framework"
COPYFILE_DISABLE=1 cp "$SPARKLE_ROOT/LICENSE" "$RESOURCE_DIR/Sparkle-LICENSE.txt"
find "$STAGED_APP" -name '._*' -type f -delete
chmod 755 "$STAGED_APP" "$STAGED_APP/Contents" "$BIN_DIR" "$RESOURCE_DIR" "$FRAMEWORK_DIR" "$HELPERS_DIR" "$BIN_DIR/DriveGauge" "$HELPERS_DIR/DriveGaugeNetworkWorker"
codesign --force --deep --sign - "$STAGED_APP"

rm -rf "$APP_DIR"
mkdir -p "$(dirname "$APP_DIR")"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$STAGED_APP" "$APP_DIR"
find "$APP_DIR" -name '._*' -type f -delete

BUILT_ARCHS="$(lipo -archs "$APP_DIR/Contents/MacOS/DriveGauge")"
if [[ "$BUILT_ARCHS" != "$TARGET_ARCH" ]]; then
    echo "Ошибка: ожидалась архитектура $TARGET_ARCH, получено: $BUILT_ARCHS" >&2
    exit 1
fi
HELPER_ARCHS="$(lipo -archs "$APP_DIR/Contents/Helpers/DriveGaugeNetworkWorker")"
if [[ "$HELPER_ARCHS" != "$TARGET_ARCH" ]]; then
    echo "Ошибка: helper ожидался $TARGET_ARCH, получено: $HELPER_ARCHS" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP_DIR"

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
DMG_STAGE="$STAGE_ROOT/dmg"
VERSIONED_DMG="$STAGE_ROOT/DriveGauge-${APP_VERSION}-arm64.dmg"
mkdir -p "$DMG_STAGE"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$STAGED_APP" "$DMG_STAGE/DriveGauge.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "DriveGauge ${APP_VERSION}" -srcfolder "$DMG_STAGE" -format UDZO -ov "$VERSIONED_DMG" >/dev/null
hdiutil verify "$VERSIONED_DMG" >/dev/null
COPYFILE_DISABLE=1 cp "$VERSIONED_DMG" "dist/DriveGauge-${APP_VERSION}-arm64.dmg"
COPYFILE_DISABLE=1 cp "$VERSIONED_DMG" "dist/DriveGauge-stable.dmg"

echo "Готово: $APP_DIR"
echo "Готово: dist/DriveGauge-${APP_VERSION}-arm64.dmg"
