# FrameBoost – PS5 30 FPS → 60/120 FPS per Capture Card (macOS)

Native Mac-App (Swift + Metal). Eigene Frame Generation, kein Lossless Scaling nötig.

**Download:** unter *Releases* → `FrameBoost.dmg`

## So funktioniert's
1. **Capture Card** wird automatisch erkannt (Elgato, AVerMedia, Cam Link, UVC/HDMI-Sticks …) und sofort gestartet, inkl. Ton.
2. **Doppelte Frames werden entfernt:** Die PS5 sendet immer 60 Hz; bei GTA mit 30 FPS ist jedes Bild doppelt. FrameBoost erkennt das und arbeitet mit den echten 30 Bildern.
3. **Bewegungsanalyse auf der GPU** (Block-Matching, grob → fein, Median-Filter), vorwärts und rückwärts.
4. **Bildsynthese bei jedem Bildschirm-Refresh:** Für jeden Bildschirm-Refresh wird genau der passende Zwischenmoment berechnet → 60 FPS auf 60-Hz-Monitoren, 120 FPS auf ProMotion/120-Hz.
5. Verdeckte Bereiche werden über Vorwärts/Rückwärts-Konsistenz erkannt; statische HUD-Elemente (Minimap) bleiben stehen.

## Bauen
`./scripts/build_dmg.sh` (macOS 14+, Xcode Command Line Tools) → `build/FrameBoost.dmg`
Selbsttest: `FrameBoost.app/Contents/MacOS/FrameBoost --selftest out/`
