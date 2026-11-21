## FrameBoost 2.4.2 – Frame Generation für Konsolen über eine Capture Card

Aus 30 FPS werden 60, 120 oder 180 FPS – mit eigener Frame Generation, ganz ohne Lossless Scaling.

**Downloads**
- **macOS** (Apple Silicon M1–M5 und Intel, macOS 14+): `FrameBoost.dmg` → FrameBoost in „Programme“ ziehen → erster Start: Rechtsklick → Öffnen
- **Windows** 10/11 (64 Bit): `FrameBoost.exe` → bei SmartScreen „Weitere Informationen → Trotzdem ausführen“

**Neu in 2.4.2**
- 1440p: Liefert die Capture Card 1440p mit vollen 60 Hz, nutzt FrameBoost das auf hochauflösenden Bildschirmen (z. B. MacBook-Retina) automatisch. Auf 1080p-Monitoren bleibt es bei 1080p. 1440p mit nur 30 Hz wird nie genommen (würde ruckeln).

**Neu in 2.4.1**
- Günstige Capture Cards: FrameBoost wählt immer ein Format mit vollem 60-Hz-Takt (manche USB-2.0-Sticks bieten 1080p nur mit 5 oder 30 Bildern/s – jetzt wird dann 720p60 genommen). Windows misst dafür die tatsächliche Bildrate der Karte.
- Getestet zusätzlich auf macOS 26 (das System der M5-Macs)
- Weniger Wartungs-Warnungen, keine abgebrochenen Testläufe mehr

**Neu in 2.4**
- Videodatei als virtuelle Capture Card (zum Ausprobieren ohne Konsole) – getestet: 30-FPS-Video → 60 FPS
- Ton-Puffer: Bild und Ton bleiben synchron
- Bis 180/240 Hz, 1:1-Ausgabe auf 1080p-Monitoren
- Neues Design, Einstellungsfenster, eingebauter Fehlerbericht
- Windows-Version mit automatischer Leistungsstufe
- Absturzsicherheit verbessert, 10-Minuten-Dauertest ohne Absturz

Vor dem Start: In der PS5 HDCP aus, 1080p, HDR aus. Details und Testergebnisse: README und TESTBERICHT.md.

---
*English:* Console frame generation through a capture card (30 → 60/120/180 FPS), macOS + Windows. MIT licensed.
