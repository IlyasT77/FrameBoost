# Testbericht FrameBoost 2.3 (19.11.2026)

Getestet wurde automatisch auf den GitHub-Build-Servern: macOS 15 (Apple-Silicon-VM mit virtueller GPU)
und Windows Server 2022 (ohne Grafikkarte). **Nicht getestet** werden konnte mit echter Capture Card und PS5.
Dafür wurden ein Demo-Signal (30-FPS-Spiel in 60 Hz, wie bei der PS5) und simulierte Tonquellen verwendet.

## Zu den GitHub-Mails „Run failed“

Die Mails kamen **nicht von Abstürzen der App**. Es waren Testläufe des Build-Servers (#14–#19, jeweils ca. 2,5 Minuten),
die fehlgeschlagen sind, während der Ton-Puffer entwickelt wurde: Der Selbsttest hat ungenaues Ton-Timing gemeldet und den
Lauf absichtlich rot markiert. Das ist behoben (siehe M7). Lauf #22 war ein Tippfehler im Testcode, den ich sofort korrigiert habe.

## Ergebnisse

| Test | macOS | Windows |
|---|---|---|
| Build | ✅ DMG (Universal: Apple Silicon + Intel) | ✅ FrameBoost.exe |
| Selbsttest (Qualität, Duplikate, Szenenwechsel, Ton-Puffer) | ✅ bestanden | ✅ bestanden (auch als EXE) |
| Bildqualität normal / schnelle Bewegung (PSNR, höher = besser) | 34,7 / 26,8 dB (Überblenden: 19,7 / 17,7) | 30,9 / 28,4 dB (Überblenden: 18,9 / 16,4) |
| Ton-Puffer: Ziel 60 / 120 ms | 57,4 / 117,8 ms ✅ | 57,4 / 117,9 ms ✅ |
| **Dauertest** (alle Funktionen in Schleife) | ✅ **10 min, 240 Aktionen, 0 Abstürze**, Speicher 57 → 59 MB | ✅ **5 min, 120 Aktionen, 0 Abstürze**, Speicher sinkt |
| Bildausgabe eingefroren | 0 × | – |
| 1080p, 180 FPS möglich | ✅ (Analyse 13 ms, Zwischenbild 2,2 ms) | auf dem Server ohne Grafikkarte nein (siehe W5) |

Der Dauertest klickt automatisch Folgendes durch, immer wieder für 10 Minuten:
- Start / Stop, auch schnell hintereinander
- alle Modi (Aus, Auto, 2×–6×) und beide Qualitätsstufen
- Schärfen, Duplikate, Vergleichsmodus und FPS-Anzeige
- Ton-Puffer an/aus, Ton-Verschiebung und Lautstärke
- Gerätesuche, Vollbild an/aus und verschiedene Fenstergrößen

Alle 5 Sekunden werden Speicher, FPS und Fehler gemessen. Die Berichte liegen in `docs/dauertest-mac.txt` und `docs/dauertest-windows.txt`.

## Gefundene und behobene Fehler

### macOS
| # | Art | Problem | Lösung |
|---|---|---|---|
| M1 | Absturzrisiko | Capture Card wurde von verschiedenen Threads gestartet und gestoppt; schnelles Start/Stop konnte eine Exception auslösen | Alle Capture-Befehle laufen auf einer festen Warteschlange (Apple-Vorgabe) |
| M2 | Absturzrisiko | Die Ton-Engine konnte gleichzeitig von zwei Threads gestoppt und gestartet werden | Lebenszyklus-Sperre im Ton-Player |
| M3 | Fehler | Ton lief nach „Stop“ kurz weiter bzw. startete wieder | Ton nimmt nach Stop nichts mehr an |
| M4 | Fehler | Eine späte Antwort der Kamera-Freigabe konnte die Karte nach „Stop“ wieder starten | Start-Zähler: veraltete Antworten werden ignoriert |
| M5 | Absturzrisiko | Demo-Signal: Start/Stop nicht synchronisiert | Start/Stop auf derselben Warteschlange wie das Signal |
| M6 | Speicher | GPU-Texturcache wurde nie geleert | Cache wird regelmäßig geleert; Dauertest: 0,2 MB/min |
| M7 | Ton | Erster Ton-Puffer (Apple-Synchronizer) – Zeitbasis blieb stehen | Ersetzt durch Ringpuffer mit Drift-Korrektur, Genauigkeit ±3 ms |
| M8 | Bild | Fahrbahnmarkierungen (sich wiederholende Muster) wurden falsch berechnet | Kleinere Bewegungen werden bei gleicher Übereinstimmung bevorzugt |
| M9 | Bild | Fehler am Bildrand bei Kameraschwenks | Inhalte vom Bildrand kommen aus dem Bild, in dem sie existieren |
| M10 | Anzeige | Maximal 120 FPS – 180-Hz-Monitore wurden nicht ausgenutzt | Bis 240 Hz, neuer 6×-Modus, 1:1-Ausgabe auf 1080p-Monitoren |
| M11 | Test | Dauertest startete ohne Fenster (Ordner als Pfad übergeben → macOS hielt ihn für eine zu öffnende Datei) | Ordner als benannte Option |

### Windows
| # | Art | Problem | Lösung |
|---|---|---|---|
| W1 | Bild | Auf langsamen PCs, deren Bewegungsanalyse länger als ein Bild dauert, entstanden nie Zwischenbilder | Zwischenbilder laufen ab dem Ende der Analyse |
| W2 | Leistung | Analyse bei 1080p zu langsam | Feste Analysebreite (1080p kostet so viel wie 720p) |
| W3 | Anzeige | FPS-Anzeige abgeschnitten | Box passt sich dem Text an |
| W4 | Meldung | Ohne Lautsprecher kryptische Fehlermeldung | Verständliche Meldung, Bild läuft weiter |

## Neu für Fehlersuche
- **Protokoll-Datei**: Mac `~/Library/Logs/FrameBoost/frameboost.log`, Windows `%LOCALAPPDATA%\FrameBoost\frameboost.log`
- **Absturz-Erkennung**: Nach einem Absturz fragt FrameBoost beim nächsten Start, ob ein Fehlerbericht erstellt werden soll
- **Fehlerbericht** (Mac: *Hilfe*, Windows: *Einstellungen*). Er enthält:
  - System, Grafikkarte, Bildschirme und Geräte
  - Einstellungen und Messwerte
  - den letzten Absturz und das Protokoll

  Die Datei landet auf dem Schreibtisch, außerdem öffnet sich die GitHub-Seite für ein Issue.

## Bekannte Grenzen / offen
- **Mit echter Capture Card + PS5 noch nicht getestet.**
- W5: Auf dem Windows-Server **ohne Grafikkarte** dauert ein Zwischenbild bei 1080p ca. 28–37 ms (nur CPU), also unter 60 FPS.
  Auf einem PC mit Grafikkarte nutzt FrameBoost OpenCL und ist deutlich schneller. Reicht die Leistung nicht, erzeugt FrameBoost
  automatisch weniger Zwischenbilder statt zu ruckeln. Die tatsächliche Leistung zeigt die FPS-Anzeige.
- Windows: Die OpenGL-Anzeige (vsync) konnte auf dem Server ohne Grafikkarte nicht geprüft werden, dort lief der Kompatibilitätsmodus.
  Falls das Bild bei dir schwarz bleibt: *Einstellungen → Kompatibilitätsmodus* aktivieren.
- Windows-EXE ist ca. 100 MB groß und braucht beim Start ein paar Sekunden (sie entpackt sich).
- Nicht signiert: Mac-Gatekeeper- bzw. Windows-SmartScreen-Warnung beim ersten Start.
- HDR wird nicht unterstützt (PS5 auf SDR stellen).
- Etwa ein echtes Bild (≈ 33 ms) zusätzliche Verzögerung – prinzipbedingt bei jeder Frame Generation.
