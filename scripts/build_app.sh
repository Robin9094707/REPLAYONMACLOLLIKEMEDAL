#!/usr/bin/env bash
# Builds "Simplex Recorder.app" (Universal: Apple Silicon + Intel), a .zip and a .dmg into ./dist
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Simplex Suite"
EXEC_NAME="SimplexRecorder"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "▶︎ Building $APP_NAME $VERSION ($BUILD_NUMBER)"
swift --version

ARCH_FLAGS=(--arch arm64 --arch x86_64)
if [[ "${UNIVERSAL:-1}" != "1" ]]; then ARCH_FLAGS=(); fi

swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▶︎ Generating icon"
if swift scripts/make_icon.swift "$DIST/icon_1024.png"; then
  ICONSET="$DIST/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$DIST/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$DIST/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "⚠︎ iconutil failed"
  rm -rf "$ICONSET"
else
  echo "⚠︎ Icon generation failed – continuing without icon"
fi

echo "▶︎ Signing (ad-hoc)"
codesign --force --deep --sign - --identifier com.simplex.recorder "$APP"
codesign --verify --verbose "$APP"
lipo -info "$APP/Contents/MacOS/$EXEC_NAME" || true

echo "▶︎ Packaging"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/SimplexSuite-$VERSION.zip"

DMG_ROOT="$DIST/dmg"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Programme"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DIST/SimplexSuite-$VERSION.dmg"
rm -rf "$DMG_ROOT" "$DIST/icon_1024.png"

echo "✅ Done:"
ls -lh "$DIST"
