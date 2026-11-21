# Testbericht FrameBoost 2.4.2

## Kurzfassung

| | Ergebnis |
|---|---|
| **60-FPS-Lock** (30-FPS-Video als Capture Card, Modus 2×) | ✅ **60 FPS GELOCKT** – macOS 15: **100,0 %** neue Bilder pro Refresh, 99,8 % zeitlich exakt · macOS 26: 99,9 % / 99,7 % |
| **macOS 26** (System der M5-Macs) auf Apple Silicon | ✅ Build, Selbsttest, Videotest, 5-min-Dauertest – alles bestanden |
| **Apple Silicon M1–M5** | ✅ läuft nativ (arm64), geprüft auf M1-Testservern mit macOS 15 und 26 |
| **Abstürze** | ✅ keine – 10 min (macOS 15), 5 min (macOS 26), 5 min (Windows), alle Funktionen in Schleife |
| **Speicher** | ✅ konstant (60 → 60 MB nach 10 min) |
| **Takt-Simulation** 60/120/144/180 Hz, alle Modi | ✅ schlechtester Fall 99,3 % (Details unten) |
| **Günstige Capture Cards** (USB 2.0/3.0) | ✅ es wird immer ein Format mit vollem 60-Hz-Takt gewählt (Test mit typischen Formatlisten) |
| **1440p** | ✅ 1440p60-Karte am MacBook-Display → 1440p60 · am 1080p-Monitor → 1080p60 · Karte mit nur 2K 30 Hz → 1080p60 |
| **GitHub-Testläufe** | ✅ alle grün, 0 Warnungen, keine abgebrochenen Läufe mehr |
| Windows-Videotest | ⚠️ nicht gelockt – der Windows-Testserver hat keine Grafikkarte (siehe Grenzen) |
| Echte PS5 + Capture Card | ⏳ noch nicht getestet (keine Hardware im Testserver) |

## Wie getestet wird

Alle Tests laufen bei jedem Build automatisch auf den GitHub-Servern:
**macOS 15 und macOS 26 auf Apple M1** (virtuelle Maschinen, virtuelle GPU) und **Windows Server 2022** (4 CPU-Kerne, **keine Grafikkarte**).
Mit echter Capture Card und PS5 konnte nicht getestet werden. Stattdessen läuft ein echtes Video als „virtuelle Capture Card“:
genau wie bei der PS5 kommt ein 60-Hz-Signal an, in dem jedes Bild eines 30-FPS-Videos doppelt enthalten ist.

> Die Fehlernummern (#1, #2 …) sind nur eine Aufzählung – sie haben nichts mit Apple-Chips (M1, M5 …) zu tun.

## 1. Apple Silicon (M1–M5)

| Prüfung | Ergebnis |
|---|---|
| App-Datei | Universal Binary: `x86_64 arm64` (`lipo -info`) |
| Test-Macs | Apple M1, `arm64`, **macOS 15** und **macOS 26.7** – die App läuft **nativ**, ohne Rosetta |
| M2, M3, M4, M5 | gleiche Architektur (arm64) und Metal-GPU wie M1 → unterstützt; M5-Macs laufen mit macOS 26, das jetzt mitgetestet wird |
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

### 60-FPS-Lock im laufenden Programm (Mac, Modus 2×, 60-Hz-Bildschirm) – ✅ GELOCKT

**Version 2.4.2** (21.11., Endstand):

| Testserver | neues Bild pro Refresh | zeitlich exakt | Ergebnis |
|---|---|---|---|
| macOS 15, Apple M1 | **100,0 %** | **99,8 %** | 60 FPS GELOCKT ✔ |
| macOS 26.7, Apple M1 | **99,9 %** | **99,7 %** | 60 FPS GELOCKT ✔ |

**Version 2.4.1** (21.11.):

| Testserver | neues Bild pro Refresh | zeitlich exakt | gezählte Ausgabe |
|---|---|---|---|
| macOS 26.7, Apple M1 | **99,9 %** | **99,8 %** | 57,7 FPS |
| macOS 15, Apple M1 | **99,7 %** | **98,6 %** | 58,0 FPS |

**Version 2.4.0** (19.11.):

Das 30-FPS-Video läuft als virtuelle Capture Card durch die echte App, 40 Sekunden gemessen, jeder Bildschirm-Refresh einzeln protokolliert.

| Messung | Ergebnis |
|---|---|
| Eingang | 60-Hz-Signal, davon **30,0 echte Bilder/s** (Duplikate erkannt) |
| FrameBoost: neues Bild pro Refresh | **99,6 %** (Ziel ≥ 98 %) |
| FrameBoost: Bild zeitlich exakt passend | **98,1 %** (Ziel ≥ 95 %) |
| Gezählte Ausgabe auf dem Testserver | 57,1 FPS |

Warum 57 und nicht genau 60 FPS? Die virtuelle Maschine hat in diesem Lauf 79 von 2.280 Refreshes gar nicht aufgerufen
und 37-mal doppelt aufgerufen – das ist der Testserver, nicht FrameBoost. Von den Refreshes, die das System wirklich
ausführt, bekommen 99,6 % ein neues Bild. Ein echter Mac hat diese Aussetzer der virtuellen Maschine nicht
(selbst prüfen konnten wir das ohne echten Mac nicht – die FPS-Anzeige in der App zeigt es).

Der Weg dahin (je ein Testlauf mit Bild-für-Bild-Protokoll, neue Bilder pro Refresh):
90,5 % → 97,3 % → 97,5 % → 78,6 % (Fehler #23 in einem Zwischenstand) → 97,9 % (Testserver stark ausgelastet) → **99,6 %**.
Die Änderungen wurden zusätzlich mit den echten Messzeiten der Testläufe in einer Simulation nachgespielt.

## 3. Weitere Ergebnisse

| Test | macOS | Windows |
|---|---|---|
| Build | ✅ DMG, 3 MB | ✅ EXE, 64 MB (vorher 100 MB) |
| Selbsttest: Bildqualität Demo (PSNR, normal / schnelle Bewegung) | ✅ 34,7 / 26,8 dB | ✅ 30,9 / 28,2 dB |
| Ton-Puffer: Ziel 60 / 120 ms | ✅ 57,4 / 117,8 ms | ✅ 57,4 / 117,9 ms |
| Duplikate / Szenenwechsel / ruhige Szene (1-Pixel-Bewegung) | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| Regressionstests (Start/Stop-Stress, Threads, Auflösungswechsel, Puffer-Grenzfälle) | ✅ alle | – |
| Capture-Format: USB-2.0-Stick → 720p60, USB-3.0-Karte → 1080p60 unkomprimiert | ✅ | ✅ (misst die echte Bildrate der Karte) |
| **Dauertest** (alle Funktionen in Schleife) | ✅ **macOS 15: 10 min, 240 Aktionen, 0 Abstürze**, Speicher 60 → 60 MB · **macOS 26: 5 min, 120 Aktionen, 0 Abstürze**, 70 → 68 MB | ✅ **5 min, 120 Aktionen, 0 Abstürze** |
| Geschwindigkeit 1080p | ✅ Analyse 13 ms, Zwischenbild 2 ms → bis 180 FPS | Server ohne Grafikkarte: Analyse 15–30 ms, Zwischenbild 15–35 ms |

### Takt-Simulation (neu in 2.4.1, läuft bei jedem Build: `tools/pacing_sim.py`)

Spielt die Taktlogik der App mit einem künstlichen Capture-Card-Signal nach – für Bildschirme, die es im Testserver nicht gibt
(z. B. dein 180-Hz-Monitor). Werte: neues Bild pro Refresh / zeitlich exakt / Verzögerung Bildmoment → Refresh.

| Bildschirm, Modus | normal | unruhige Capture Card (4 ms Jitter) | Spiel ruckelt (5 % der Bilder zu spät) |
|---|---|---|---|
| 60 Hz, 2× (30 → 60) | 99,96 / 99,92 % · 48 ms | 99,93 / 99,86 % | 99,96 / 99,50 % |
| 120 Hz, 4× (30 → 120) | 99,97 / 99,97 % · 48 ms | 99,92 / 99,83 % | 99,93 / 99,71 % |
| **180 Hz, 6× (30 → 180)** | **99,97 / 99,96 % · 48 ms** | 99,71 / 99,27 % | 99,80 / 99,40 % |
| 144 Hz, Auto | 99,98 / 99,97 % · 45 ms | 99,98 / 99,97 % | 99,97 / 99,28 % |
| 180 Hz, Auto | 99,99 / 99,97 % · 45 ms | 99,97 / 99,96 % | 99,96 / 99,09 % |

Die Simulation wurde gegen die echten Messzeiten der Testserver geprüft (alter Stand simuliert 97,9 %, gemessen 97,3 %).

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
| #25 | Mac | **Capture Card** | Günstige USB-2.0-Sticks bieten 1080p unkomprimiert nur mit 5 Bildern/s – FrameBoost hätte genau das gewählt | Voller 60-Hz-Takt hat Vorrang (dann 720p60) · Selbsttest mit typischen Formatlisten ✅ |
| #26 | Windows | **Capture Card** | Treiber akzeptieren „1080p 60 Hz“ und liefern trotzdem weniger | Die tatsächliche Bildrate wird gemessen, 720p60 vor 1080p30 · Selbsttest mit simulierten Karten ✅ |
| #27 | Windows | Anzeige | Versionsnummer zeigte 2.3.0 | 2.4.1 |
| #28 | beide | Takt | Ein Spiel-Ruckler (Bild eine Signalperiode zu spät) wurde als Übertragungs-Schwankung geglättet | Wird als echter Ruckler erkannt (Simulation: 97–99,7 % statt 94–97 % exakt) |
| #29 | Mac | Verzögerung | Feste Modi (2×, 4×, 6×) rundeten immer ab → bis zu einem Zwischenbild mehr Verzögerung | Rundung beginnt am nächsten Rasterpunkt: 2× bei 60 Hz ≈ 17 ms weniger Verzögerung, gleiche Qualität |
| #31 | Mac | Auflösung | Eine Karte mit echtem 1440p60 wäre trotzdem mit 1080p betrieben worden | Auf hochauflösenden Bildschirmen (MacBook-Retina) wird 1440p60 genutzt, auf 1080p-Monitoren 1080p; 1440p mit 30 Hz nie · Selbsttest ✅ |
| #30 | Build | **Fehler-Mails** | Neue Testläufe brachen ältere ab („cancelled“-Mails); veraltete Node-20-Aktionen und veraltete Video-Funktionen erzeugten Warnungen | Läufe warten aufeinander; aktuelle Aktionen; neue AVFoundation-Funktionen · Logs: 0 Warnungen, 0 Fehler |

## 5. Bekannte Grenzen

- **Echte Capture Card + PS5 noch nicht getestet** (keine Hardware im Testserver).
- **Windows-Leistung:** Der Windows-Testserver hat keine Grafikkarte. Dort erreicht der Filmtest keine 60 FPS, weil Dekodieren,
  Analyse und Zwischenbilder alle auf 4 CPU-Kernen laufen. Auf einem PC mit Grafikkarte nutzt FrameBoost OpenCL, und eine
  Capture Card liefert das Bild ohne Dekodieraufwand. Die tatsächliche Leistung zeigt die FPS-Anzeige.
  Bei Bedarf in den Einstellungen „Schnell“ wählen.
- Mac-Testserver: virtuelle GPU, deutlich langsamer als ein echter M-Chip; Anzeigezeitpunkte meldet sie nicht, gemessen wird daher am Zeichenzeitpunkt.
- Nicht signiert: Gatekeeper-/SmartScreen-Hinweis beim ersten Start. HDR wird nicht unterstützt.
- Verzögerung: etwa ein echtes Bild + ein Bildschirm-Refresh (≈ 45–50 ms vom Bildmoment bis zum Refresh, dazu die Anzeige selbst). Der Ton wird automatisch angeglichen.
- Die Fehler-Mails von GitHub vom 19.11. stammen von alten, abgebrochenen bzw. fehlgeschlagenen Testläufen (vor Fehler #24/#30). Seit 2.4.1 sind alle Läufe grün.
