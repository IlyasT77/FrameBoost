# FrameBoost signieren (ohne Warnung beim Öffnen)

Damit macOS die App ohne „Rechtsklick → Öffnen“ startet, muss sie mit einem **Developer ID**-Zertifikat
signiert und von Apple **notarisiert** werden. Das Zertifikat gibt es nur über das
**Apple Developer Program (99 €/Jahr)**. Kostenlose Zertifikate funktionieren dafür nicht.

Der Build ist schon vorbereitet: Sobald die 5 Secrets unten eingetragen sind, signiert und notarisiert
GitHub die DMG automatisch.

## 1. Apple Developer Program
developer.apple.com/programs → mit deiner Apple-ID anmelden → Mitglied werden (Freischaltung dauert meist 1–2 Tage).

## 2. Zertifikat erstellen (am Mac)
1. Xcode installieren und öffnen → Einstellungen → Accounts → Apple-ID hinzufügen
2. „Manage Certificates…“ → **+** → **Developer ID Application**
3. Schlüsselbundverwaltung öffnen → „Meine Zertifikate“ → *Developer ID Application: …* → Rechtsklick → **Exportieren** als `.p12` mit Passwort
4. Terminal: `base64 -i Zertifikat.p12 | pbcopy` (kopiert es in die Zwischenablage)

## 3. App-spezifisches Passwort
appleid.apple.com → Anmelden & Sicherheit → **App-spezifische Passwörter** → neues erstellen („FrameBoost Notarisierung“).

## 4. Secrets in GitHub eintragen
Repo → Settings → Secrets and variables → Actions → **New repository secret**:

| Name | Inhalt |
|---|---|
| `MACOS_CERT_P12` | der base64-Text aus Schritt 2.4 |
| `MACOS_CERT_PASSWORD` | Passwort der `.p12`-Datei |
| `NOTARY_APPLE_ID` | deine Apple-ID (E-Mail) |
| `NOTARY_TEAM_ID` | Team-ID (developer.apple.com → Account → Membership) |
| `NOTARY_PASSWORD` | das App-spezifische Passwort aus Schritt 3 |

Danach den Build neu starten (Actions → Build macOS DMG → Run workflow). Die neue DMG öffnet sich ohne Warnung.
