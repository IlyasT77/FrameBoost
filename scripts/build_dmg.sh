#!/bin/bash
# Builds FrameBoost.app (Universal: Apple Silicon + Intel) and FrameBoost.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/FrameBoost"
APP="build/FrameBoost.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FrameBoost"

# icon
"$BIN" --make-icon build/icon.png
mkdir -p build/icon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FrameBoost</string>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>CFBundleLocalizations</key><array><string>de</string></array>
  <key>CFBundleDisplayName</key><string>FrameBoost</string>
  <key>CFBundleExecutable</key><string>FrameBoost</string>
  <key>CFBundleIdentifier</key><string>app.frameboost.mac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>FrameBoost braucht Zugriff auf deine Capture Card, um das PS5-Bild anzuzeigen.</string>
  <key>NSMicrophoneUsageDescription</key><string>FrameBoost braucht Zugriff auf den Ton deiner Capture Card.</string>
</dict></plist>
PLIST

# ---------------------------------------------------------------- signing
# With an Apple "Developer ID Application" certificate (SIGN_IDENTITY set, see SIGNIEREN.md) the app is
# signed with hardened runtime and later notarized -> opens without any warning.
# Without it: ad-hoc signature (first start: right click -> Open).
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --entitlements scripts/entitlements.plist --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

# ---------------------------------------------------------------- installer window
"$BIN" --make-dmg-background build/dmg-bg.png 1
"$BIN" --make-dmg-background build/dmg-bg@2x.png 2
tiffutil -cathidpicheck build/dmg-bg.png build/dmg-bg@2x.png -out build/dmg-bg.tiff

rm -f build/FrameBoost.dmg
STAGE=build/dmg && rm -rf "$STAGE" && mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/"
if command -v create-dmg >/dev/null; then
  # Finder lays out the window itself (background, icon positions, drag target)
  create-dmg --volname "FrameBoost" --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --background build/dmg-bg.tiff --window-pos 200 140 --window-size 660 420 \
    --icon-size 112 --text-size 13 --icon "FrameBoost.app" 165 200 --hide-extension "FrameBoost.app" \
    --app-drop-link 495 200 --no-internet-enable \
    build/FrameBoost.dmg "$STAGE"
else
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "FrameBoost" -srcfolder "$STAGE" -ov -format UDZO build/FrameBoost.dmg
fi

# ---------------------------------------------------------------- notarization
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" build/FrameBoost.dmg
  if [ -n "${NOTARY_APPLE_ID:-}" ]; then
    xcrun notarytool submit build/FrameBoost.dmg --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" --wait
    xcrun stapler staple build/FrameBoost.dmg
    spctl -a -t open --context context:primary-signature -v build/FrameBoost.dmg
  fi
fi
echo "DMG: build/FrameBoost.dmg"
