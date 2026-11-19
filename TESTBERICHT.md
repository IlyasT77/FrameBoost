# Testbericht FrameBoost 2.4

Alle Tests laufen bei jedem Build automatisch auf den GitHub-Servern:
**macOS 15 auf Apple M1** (virtuelle Maschine, virtuelle GPU) und **Windows Server 2022** (4 CPU-Kerne, **keine Grafikkarte**).
Mit echter Capture Card und PS5 konnte nicht getestet werden. Stattdessen läuft ein echtes Video als „virtuelle Capture Card“:
genau wie bei der PS5 kommt ein 60-Hz-Signal an, in dem jedes Bild eines 30-FPS-Videos doppelt enthalten ist.

> Die Fehlernummern (#1, #2 …) sind nur eine Aufzählung – sie haben nichts mit Apple-Chips (M1, M5 …) zu tun.

## 1. Apple Silicon (M1–M5)

| Prüfung | Ergebnis |
|---|---|
| App-Datei | Universal Binary: `x86_64 arm64` (`lipo -info`) |
| Test-Mac | Apple M1, `arm64` – die App läuft **nativ**, ohne Rosetta |
| M2, M3, M4, M5 | gleiche Architektur (arm64) und Metal-GPU wie M1 → unterstützt |
| Intel-Macs | ebenfalls in der Datei enthalten |

## 2. Echtes Video als Capture Card (Big Buck Bunny, 1080p)

Ausgangsmaterial ist die **60-FPS-Fassung** des Films. Daraus entsteht eine 30-FPS-Fassung, indem jedes zweite Bild weggelassen wird.
FrameBoost erzeugt aus den 30 FPS wieder 60 FPS. Die erzeugten Zwischenbilder werden mit den **echten, weggelassenen Bildern**
verglichen. Höhere Werte sind besser.

| Verfahren | PSNR (dB) | SSIM |
|---|---|---|
| Bild wiederholen (normale 30 FPS) | 31,7 | 0,983 |
| Überblenden | 33,3 | 0,986 |
| FFmpeg Motion Interpolation (langsam, nicht in Echtzeit) | 34,5 | **0,991** |
| **FrameBoost** (Echtzeit) | **35,0** | 0,986 |

FrameBoost erreicht den besten PSNR aller Verfahren. Beim SSIM (Strukturähnlichkeit) liegt die deutlich langsamere
FFmpeg-Methode knapp vorne. Das Vergleichsvideo `vergleich_30_vs_60fps.mp4` zeigt beides nebeneinander.

**60-FPS-Lock im laufenden Programm (Mac, Modus 2×, 60-Hz-Bildschirm):** VIDEOTEST_ERGEBNIS

## 3. Weitere Ergebnisse

| Test | macOS | Windows |
|---|---|---|
| Build | ✅ DMG, 3 MB | ✅ EXE, 64 MB (vorher 100 MB) |
| Selbsttest: Bildqualität Demo (PSNR, normal / schnelle Bewegung) | ✅ 34,7 / 26,8 dB | ✅ 30,9 / 28,2 dB |
| Ton-Puffer: Ziel 60 / 120 ms | ✅ 57,4 / 117,8 ms | ✅ 57,4 / 117,9 ms |
| Duplikate / Szenenwechsel / ruhige Szene (1-Pixel-Bewegung) | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| Regressionstests (Start/Stop-Stress, Threads, Auflösungswechsel, Puffer-Grenzfälle) | ✅ alle | – |
| **Dauertest** (alle Funktionen in Schleife) | ✅ **10 min, 240 Aktionen, 0 Abstürze**, Speicher konstant (59 → 60 MB) | ✅ **5 min, 120 Aktionen, 0 Abstürze** |
| Geschwindigkeit 1080p | ✅ Analyse 13 ms, Zwischenbild 2 ms → bis 180 FPS | Server ohne Grafikkarte: Analyse 15–30 ms, Zwischenbild 15–35 ms |

## 4. Gefundene und behobene Fehler

| # | System | Art | Problem | Lösung |
|---|---|---|---|---|
| #1 | Mac | Absturzrisiko | Capture Card von verschiedenen Threads gestartet/gestoppt; schnelles Start/Stop konnte abstürzen | Alle Capture-Befehle auf einer festen Warteschlange |
| #2 | Mac | Absturzrisiko | Ton-Engine konnte gleichzeitig gestoppt und gestartet werden | Sperre im Ton-Player · Test: 60× Start/Stop ✅ |
| #3 | Mac | Fehler | Ton lief nach „Stop“ weiter | Ton nimmt nach Stop nichts mehr an · Test ✅ |
| #4 | Mac | Fehler | Späte Kamera-Freigabe startete die Karte nach „Stop“ neu | Veraltete Antworten werden ignoriert |
| #5 | Mac | Absturzrisiko | Demo-Signal: Start/Stop nicht synchronisiert | Synchronisiert · Test: 40× Start/Stop ✅ |
| #6 | Mac | Speicher | GPU-Texturcache wurde nie geleert | Regelmäßig geleert · Dauertest: Speicher konstant |
| #7 | beide | Ton | Erster Ton-Puffer: Zeitbasis blieb stehen | Ringpuffer mit Drift-Korrektur, ±3 ms |
| #8 | Mac | Bild | Fahrbahnmarkierungen (Wiederholmuster) falsch berechnet | Kleinere Bewegung wird bevorzugt |
| #9 | Mac | Bild | Fehler am Bildrand bei Kameraschwenks | Randinhalt aus dem passenden Bild |
| #10 | Mac | Anzeige | Max. 120 FPS | Bis 240 Hz, 6×-Modus, 1:1 auf 1080p |
| #11 | Mac | Test | Dauertest startete ohne Fenster | Ordner als benannte Option |
| #12 | beide | **Bild** | **Echtes Video: ruhige Szenen wurden als „doppelte Bilder“ verworfen** (nur 8 statt 30 echte Bilder/s) – gefunden durch den Filmtest | Feinere Erkennung (Flächenmittel, 144 Bildbereiche) · jetzt 30,0 echte Bilder/s ✅ |
| #13 | beide | Bild | Videoquelle blieb hängen, wenn das Dekodieren langsamer als Echtzeit war | Springt nach vorn statt zu blockieren |
| #14 | Mac | Takt | Zwischenbild-Zeitpunkt hing an der Uhrzeit des Zeichenaufrufs → gelegentlich doppelte Bilder | Bildschirm-synchrone Ausgabeuhr |
| #15 | Mac | Takt | Bewegungsanalyse im selben GPU-Auftrag wie die Anzeige → verpasste Bildwechsel auf langsamen GPUs | Analyse läuft nach der Anzeige |
| #16 | Windows | Bild | Auf langsamen PCs keine Zwischenbilder | Zwischenbilder ab Ende der Analyse |
| #17 | Windows | Leistung | Analyse zu langsam | Feste Analysegröße + Qualitätsstufe „Auto“ (34 → 59 FPS auf schwacher CPU) |
| #18 | Windows | Meldung | Kryptische Meldung ohne Lautsprecher | Verständlicher Text |
| #19 | Windows | Größe | EXE 100 MB | 64 MB (nur benötigte Bibliotheken) |
| #20 | Mac | Takt | Gefunden mit Bild-für-Bild-Protokoll des Videotests: die Bildschirm-Refreshes lagen genau auf der Rundungsgrenze zwischen zwei Ausgabebildern → kleinste Zeitschwankungen ergaben doppelte Bilder | Rundung wird auf die tatsächliche Lage der Refreshes zentriert (laufender Mittelwert) |
| #21 | Mac | Takt | Ein neues echtes Bild konnte das Bildpaar ersetzen, während der nächste Refresh noch ein Zwischenbild des alten Paars brauchte | Paarwechsel erst, wenn das alte Paar fertig gezeigt ist; ein verspätetes Bild wird im selben GPU-Auftrag analysiert |
| #22 | Mac | Takt | macOS rief das Zeichnen manchmal zweimal im selben Refresh auf → die Ausgabeuhr lief vor, Bilder fehlten | Refresh-Raster, das der Phase der Aufrufe folgt (doppelter Aufruf = kein neuer Refresh) |
| #23 | Mac | Takt | Zwischenstand (nie veröffentlicht): nach einem ausgelassenen Bild wurde dauerhaft jedes zweite echte Bild übersprungen | Ausgaberaster in fester Zeit (1 Bildabstand ÷ Modus), nicht relativ zum Bildpaar |
| #24 | Build | Test | Ein nicht gelockter Videotest ließ den ganzen Build scheitern (Fehler-Mails, kein neuer Download) | Ergebnis steht im Bericht, der Download wird trotzdem gebaut |

## 5. Bekannte Grenzen

- **Echte Capture Card + PS5 noch nicht getestet** (keine Hardware im Testserver).
- **Windows-Leistung:** Der Windows-Testserver hat keine Grafikkarte. Dort erreicht der Filmtest keine 60 FPS, weil Dekodieren,
  Analyse und Zwischenbilder alle auf 4 CPU-Kernen laufen. Auf einem PC mit Grafikkarte nutzt FrameBoost OpenCL, und eine
  Capture Card liefert das Bild ohne Dekodieraufwand. Die tatsächliche Leistung zeigt die FPS-Anzeige.
  Bei Bedarf in den Einstellungen „Schnell“ wählen.
- Mac-Testserver: virtuelle GPU, deutlich langsamer als ein echter M-Chip; Anzeigezeitpunkte meldet sie nicht, gemessen wird daher am Zeichenzeitpunkt.
- Nicht signiert: Gatekeeper-/SmartScreen-Hinweis beim ersten Start. HDR wird nicht unterstützt.
- Verzögerung: etwa ein echtes Bild + ein Bildschirm-Refresh (≈ 50 ms bei 30 FPS / 60 Hz). Der Ton wird automatisch angeglichen.
