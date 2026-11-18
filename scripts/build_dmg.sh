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

codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

# DMG with drag-to-Applications
STAGE=build/dmg && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/ZUERST LESEN.txt" <<TXT
FrameBoost installieren:
1. FrameBoost in den Ordner "Programme" (Applications) ziehen.
2. Beim ersten Start: Rechtsklick auf FrameBoost -> "Öffnen" -> "Öffnen".
   (Die App ist nicht bei Apple notarisiert. Falls "beschädigt" erscheint:
    Terminal öffnen und eingeben:  xattr -cr /Applications/FrameBoost.app )
3. Kamera- und Mikrofon-Zugriff erlauben (das ist die Capture Card).

PS5 vorbereiten:
- Einstellungen -> System -> HDMI -> "HDCP aktivieren" AUS (sonst schwarzes Bild).
- OBS, QuickTime oder Elgato-Software schließen (sonst ist die Karte belegt).

Bedienung: Karte wird automatisch erkannt und gestartet.
Frame Gen "Auto" = so viele FPS wie dein Bildschirm kann (60 Hz -> 60, ProMotion -> 120).
Vollbild: Ctrl+Cmd+F.  Cmd+0 Aus, Cmd+1 Auto, Cmd+2 2x, Cmd+4 4x.
TXT
rm -f build/FrameBoost.dmg
hdiutil create -volname "FrameBoost" -srcfolder "$STAGE" -ov -format UDZO build/FrameBoost.dmg
echo "DMG: build/FrameBoost.dmg"
