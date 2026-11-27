#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="1.4.3"
BUILD_NUM="21"
APP_NAME="WetShaveJournal"
APP_DISPLAY_NAME="湿剃日记"
ARCH_TAG="arm64"
STAGE_DIR="/tmp/WetShaveJournal_stage"
DMG_STAGE_DIR="/tmp/WetShaveJournal_dmg_stage"
APP="${STAGE_DIR}/${APP_NAME}.app"
SYS_APP="/Applications/${APP_NAME}.app"
DRIVE_BACKUP_DIR="$(dirname "$SCRIPT_DIR")/WetShaveJournal_Backup"
if [ -d "$DRIVE_BACKUP_DIR" ]; then
  OUTPUT_APP_DIR="${WSJ_OUTPUT_APP_DIR:-$DRIVE_BACKUP_DIR/App}"
  OUTPUT_REL_DIR="${WSJ_OUTPUT_REL_DIR:-$DRIVE_BACKUP_DIR/Releases}"
else
  FALLBACK_DIR="${WSJ_DATA_DIR:-$HOME/Library/Application Support/WetShaveJournal}"
  OUTPUT_APP_DIR="${WSJ_OUTPUT_APP_DIR:-$FALLBACK_DIR}"
  OUTPUT_REL_DIR="${WSJ_OUTPUT_REL_DIR:-$FALLBACK_DIR}"
fi
TMP_BIN="/tmp/WetShaveJournal_build"
TMP_CACHE="/tmp/swift_module_cache"
SDK_PATH="${WSJ_SDK_PATH:-$(xcrun --show-sdk-path)}"

# 可选正式发布签名/公证环境变量（本地默认走 ad-hoc 签名，绝不伪造 Developer ID 状态）：
#   WSJ_APP_SIGN_IDENTITY="Developer ID Application: ..."
#   WSJ_PKG_SIGN_IDENTITY="Developer ID Installer: ..."
#   WSJ_NOTARY_PROFILE="AC_PASSWORD_PROFILE"
APP_SIGN_IDENTITY="${WSJ_APP_SIGN_IDENTITY:--}"
PKG_SIGN_IDENTITY="${WSJ_PKG_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${WSJ_NOTARY_PROFILE:-}"

mkdir -p "$TMP_CACHE"
rm -rf "$STAGE_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "[1/5] Compiling WetShaveJournal v${VERSION} (Build ${BUILD_NUM})..."
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -sdk "$SDK_PATH" \
  -module-cache-path "$TMP_CACHE" \
  -framework SwiftUI -framework Charts -framework AppKit -framework Foundation -framework UniformTypeIdentifiers -framework Security \
  "$SCRIPT_DIR/Sources/WetShaveJournal/"*.swift \
  -o "$TMP_BIN"

echo "[2/5] Updating app bundle resources & Info.plist..."
cp "$TMP_BIN" "$APP/Contents/MacOS/WetShaveJournal"
chmod +x "$APP/Contents/MacOS/WetShaveJournal"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$SCRIPT_DIR/Resources/read-notes.js" "$APP/Contents/Resources/read-notes.js"
if [ -d "$SCRIPT_DIR/Resources/BrandLogos" ]; then
  rm -rf "$APP/Contents/Resources/BrandLogos"
  cp -R "$SCRIPT_DIR/Resources/BrandLogos" "$APP/Contents/Resources/BrandLogos"
  find "$APP/Contents/Resources/BrandLogos" -name ".DS_Store" -delete
fi

cat << EOF > "$APP/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>WetShaveJournal</string>
    <key>CFBundleIdentifier</key><string>com.personal.wetshavejournal</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUM}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSAppleEventsUsageDescription</key><string>读取你的 SOTD 备忘录表格并生成本地日记。</string>
</dict>
</plist>
EOF

echo "[3/5] Signing ${APP} (identity: ${APP_SIGN_IDENTITY})..."
touch "$APP"
if [ "$APP_SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$APP_SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "[4/5] Packaging .app, .zip, .dmg into ${OUTPUT_APP_DIR}..."
mkdir -p "$OUTPUT_APP_DIR" "$OUTPUT_REL_DIR"
rm -rf "$OUTPUT_APP_DIR/${APP_NAME}.app"
ditto "$APP" "$OUTPUT_APP_DIR/${APP_NAME}.app"

ZIP_PATH="$OUTPUT_APP_DIR/${APP_NAME}-${VERSION}-${ARCH_TAG}.zip"
DMG_PATH="$OUTPUT_APP_DIR/${APP_NAME}-${VERSION}-${ARCH_TAG}.dmg"
rm -f "$ZIP_PATH" "$DMG_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_PATH"

rm -rf "$DMG_STAGE_DIR"
mkdir -p "$DMG_STAGE_DIR"
ditto "$APP" "$DMG_STAGE_DIR/${APP_DISPLAY_NAME}.app"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

hdiutil create \
  -volname "${APP_DISPLAY_NAME} ${VERSION}" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
rm -rf "$DMG_STAGE_DIR"

if [ "$APP_SIGN_IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$APP_SIGN_IDENTITY" "$DMG_PATH"
fi

if [ -n "$NOTARY_PROFILE" ] && [ "$APP_SIGN_IDENTITY" != "-" ]; then
  echo "Submitting ${DMG_PATH} for Apple notarization (profile: ${NOTARY_PROFILE})..."
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
fi

echo "[5/5] Packaging clean source archive..."
TMP_SRC="/tmp/${APP_NAME}-${VERSION}-source"
rm -rf "$TMP_SRC"
mkdir -p "$TMP_SRC"
cp "$SCRIPT_DIR/Package.swift" "$SCRIPT_DIR/build.sh" "$TMP_SRC/"
[ -f "$SCRIPT_DIR/CHANGES_v1.1.0.md" ] && cp "$SCRIPT_DIR/CHANGES_v1.1.0.md" "$TMP_SRC/"
cp -R "$SCRIPT_DIR/Sources" "$TMP_SRC/Sources"
cp -R "$SCRIPT_DIR/Resources" "$TMP_SRC/Resources"
[ -d "$SCRIPT_DIR/Tests" ] && cp -R "$SCRIPT_DIR/Tests" "$TMP_SRC/Tests"
find "$TMP_SRC" -name ".DS_Store" -delete
SRC_ZIP_PATH="$OUTPUT_APP_DIR/${APP_NAME}-${VERSION}-source.zip"
rm -f "$SRC_ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$TMP_SRC" "$SRC_ZIP_PATH"
rm -rf "$TMP_SRC"

if [ "$OUTPUT_REL_DIR" != "$OUTPUT_APP_DIR" ]; then
  cp -f "$ZIP_PATH" "$DMG_PATH" "$SRC_ZIP_PATH" "$OUTPUT_REL_DIR/"
fi

# 尝试同步更新 /Applications/WetShaveJournal.app（若权限允许）
if [ -w "/Applications" ]; then
  if rm -rf "$SYS_APP" 2>/dev/null && ditto "$APP" "$SYS_APP" 2>/dev/null; then
    echo "Updated $SYS_APP to v${VERSION} (Build ${BUILD_NUM})."
  fi
fi

echo ""
echo "Build & packaging complete (v${VERSION}, Build ${BUILD_NUM}):"
echo "  Signing: $([ "$APP_SIGN_IDENTITY" = "-" ] && echo "ad-hoc (local build only)" || echo "$APP_SIGN_IDENTITY")"
echo "  App:     $OUTPUT_APP_DIR/${APP_NAME}.app"
echo "  Zip:     $ZIP_PATH"
echo "  Dmg:     $DMG_PATH"
echo "  Source:  $SRC_ZIP_PATH"
echo ""
echo "SHA-256 checksums:"
shasum -a 256 "$DMG_PATH" "$ZIP_PATH" "$SRC_ZIP_PATH"
