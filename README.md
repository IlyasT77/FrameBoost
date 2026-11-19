# FrameBoost – PS5 30 FPS → 60/120 FPS per Capture Card (macOS)

Native Mac-App (Swift + Metal) mit **eigener Frame Generation**, kein Lossless Scaling nötig.

**Download:** [Releases → FrameBoost.dmg](../../releases/latest)

## Installieren
1. DMG öffnen, **FrameBoost** in **Programme** ziehen.
2. Erster Start: **Rechtsklick → Öffnen → Öffnen** (App ist nicht bei Apple notarisiert).
   Erscheint „beschädigt“: Terminal → `xattr -cr /Applications/FrameBoost.app`
3. Kamera- und Mikrofon-Zugriff erlauben (das ist die Capture Card).

## PS5 vorbereiten
- Einstellungen → System → HDMI → **„HDCP aktivieren“ AUS** (sonst schwarzes Bild)
- Einstellungen → Bildschirm und Video → **HDR aus** (Capture Cards zeigen HDR meist blass)
- OBS, QuickTime und Elgato-Software schließen (sonst ist die Karte belegt)

## Bedienung
Capture Card einstecken → wird automatisch erkannt und gestartet (inkl. Ton).

| Taste | Funktion |
|---|---|
| ⌃⌘F | Vollbild |
| ⌘0 / ⌘1 / ⌘2 / ⌘3 / ⌘4 / ⌘6 | Frame Gen Aus / Auto / 2× / 3× / 4× / 6× |
| ⌘I | FPS-Anzeige |
| ⇧⌘S | Start / Stop |

**Auto** = so viele Bilder wie dein Bildschirm kann (60 Hz → 60 FPS, 120 Hz → 120 FPS, 180 Hz → 180 FPS).
Auf einem 180-Hz-Monitor laufen Auto (180), 3× (90) und 2× (60) besonders gleichmäßig.

**Ton:** läuft durch einen Puffer und wird genau so lange verzögert wie das Bild (Bild und Ton synchron).
Feinabstimmung in den Einstellungen; Test: Demo-Signal → weißes Quadrat und Piepton kommen gleichzeitig.

**1080p-Monitor:** 1080p-Capture im Vollbild wird 1:1 angezeigt, ohne Skalierung.

## So funktioniert die Frame Generation
1. **Doppelte Frames entfernen:** Die PS5 sendet immer 60 Hz; bei 30 FPS ist jedes Bild doppelt. FrameBoost erkennt das (Schwelle passt sich dem Rauschen der Karte an) und arbeitet mit den echten Bildern.
2. **Bewegungsanalyse auf der GPU** in 4 Stufen (1/8 → 1/4 → 1/2 Auflösung), vorwärts und rückwärts, 16-px-Raster mit Sub-Pixel-Genauigkeit (über 1080p automatisch 32 px, damit es flüssig bleibt), plus Vorhersage aus dem letzten Bildpaar für schnelle Kameraschwenks.
3. **Bildsynthese bei jedem Bildschirm-Refresh:** Pro Pixel werden 9 Bewegungskandidaten verglichen und der passendste gewählt. Das gibt saubere Kanten an Autos und Figuren. Verdeckte Bereiche werden erkannt, HUD/Minimap bleiben stehen.
4. **Szenenwechsel** (Menü, Kameraschnitt) werden erkannt; dort wird nicht gemorpht.
5. Ausgabe skaliert auf Fenster/Vollbild, mit optionalem Nachschärfen.

Verzögerung: etwa ein echtes Bild (≈33 ms bei 30 FPS). Das ist bei jeder Frame Generation so.

## Selbst bauen
`./scripts/build_dmg.sh` (macOS 14+, Xcode Command Line Tools) → `build/FrameBoost.dmg`
Selbsttest: `FrameBoost.app/Contents/MacOS/FrameBoost --selftest out/`
