# Döner-App 🥙

**Der beste Döner der Stadt – empfohlen von Leuten in deiner Umgebung.**

Eine lokale Döner-Community für iOS, Android und Web aus einer Codebase. Wer in der Nähe Döner isst, bewertet die Läden nach Soße, Fleisch und Brot. Daraus entstehen das Ranking der Stadt und die Trends im Umkreis. Freunde verbinden sich per QR-Code und sehen, wo der andere gerade isst.

Die App wird gerade auf diese Ausrichtung umgebaut. Was beschlossen, aber noch nicht gebaut ist, steht unter [Umbau](#umbau). Alle anderen Abschnitte beschreiben den Stand im Code.

---

## Überblick

Die Döner-App zeigt die besten Döner-Läden der Umgebung und das Ranking der Stadt, gebildet aus den Bewertungen nach Soße/Fleisch/Brot. Ein Check-in vor Ort zeigt den Freunden, wo man gerade isst. Dazu kommen eine persönliche Stempelkarte und die eigene Döner-Geschichte.

**Stack:**
- App: Flutter (iOS, Android, Web), Google Maps (google_maps_flutter), sembast als lokaler Store
- Server: Dart (shelf), PostgreSQL – liefert auch die Web-App aus
- Geteilt: `packages/doener_models` – DTOs, Validierung und Gamification-Regeln für App und Server
- Läden: Google Places API (New), serverseitig abgefragt und gecacht
- Login: E-Mail-Code bzw. Magic-Link, kein Passwort; Pflicht, samt eigenem Anzeigenamen statt „Döner-Fan-1234“

---

## Features

### Karte

Die Karte lädt Dönerläden für den sichtbaren Ausschnitt (nur bis 0,5° Span). Der Server fragt Google pro Kachel (0,03°) höchstens alle 25 Tage ab, auch leere Kacheln werden gemerkt. Das hält die Google-Kosten klein. Erkannt werden Läden über den Namen (Döner, Kebap, Dürüm, Yufka …) oder den Google-Typ (z. B. türkisches Restaurant).

Google erlaubt, Laden-Details höchstens 30 Tage zu speichern (nur die Place ID unbegrenzt) und Places-Daten nur auf Google-Karten zu zeigen. Deshalb: Karte von Google Maps, ein täglicher Job auf dem Server frischt Läden mit Besuchen oder Bewertungen auf und löscht ungenutzte nach 30 Tagen, die App verwirft ihren lokalen Cache ebenso. Listen ohne Karte tragen den Hinweis „Ortsdaten: Google Maps“.

- Pins: orange, besuchte Läden grün, Favoriten pink; fremde Geschäfts-POIs sind ausgeblendet
- Lupe oben rechts: Suche in allen Läden, die die App schon kennt; daneben der Favoriten-Filter per Herz
- „Laden fehlt?“ oben links schickt eine Meldung samt Kartenposition an den Server

### Check-In

Eingecheckt wird nur vor Ort, über den 🥙-Knopf in der Mitte der Tab-Leiste. Er ist orange, sobald ein Laden höchstens 150 m entfernt ist, sonst grau. Dafür lädt die App die Läden rund um den Standort und verfolgt ihn, solange sie offen ist. Ein Tipp auf den grauen Knopf fragt nach dem Standort, falls er noch nicht freigegeben ist, und lädt die Läden in der Nähe neu. Den Abstand prüft nur die App: Koordinaten ließen sich ohnehin fälschen, deshalb verzichtet der Server darauf, solange keine Fakes auftauchen.

Danach kommt ein Drehrad mit 6 Essenstypen (Döner, Yufka, Lahmacun, Teller, Pommes, Falafel), das oberste Symbol ist ausgewählt. Stehen mehrere Läden nebeneinander, wählt man vorher den richtigen aus. Nach dem Check-in regnet es Emojis des gewählten Essens. Einen Kommentar gibt es nicht.

- Check-ins werden sofort lokal gespeichert und über eine Sync-Queue an den Server geschickt
- Die ID erzeugt der Client, deshalb entstehen bei Wiederholungen keine doppelten Besuche
- Ein Check-in setzt für eine Stunde den Live-Status („isst gerade bei …“), aber nur wenn er wirklich gerade passiert

### Bewertungen

Ein Gesamtrating (1–5) plus drei optionale Dimensionen: Soße, Fleisch, Brot. Das Gesamtrating ist automatisch der Durchschnitt der Dimensionen und kann manuell überschrieben werden.

- Eine Bewertung pro Nutzer und Laden – eine neue ersetzt die alte
- „Was macht den Laden besonders?“ gehört zur eigenen Bewertung; der Laden zeigt die jüngste solche Notiz
- Durchschnitt und Anzahl berechnet der Server beim Lesen, nichts wird doppelt gespeichert
- In der Laden-Ansicht: eigene Bewertung, Community-Zusammenfassung und Bewertungen anderer

### Profil & Stempelkarte

Das Profil ist der persönliche Döner-Pass: Besuche, Bewertungen, Läden, Döner-Konsum nach Essenstyp und „Seit [Monat Jahr]“ ab dem ersten Check-in. Dort liegen auch „Meine Aktivität“ (eigene Check-ins und Bewertungen, noch nicht übertragene sind markiert) und „Meine Läden“ (alle besuchten oder bewerteten Läden, sortierbar nach Bewertung, Besuchen oder zuletzt besucht).

| Stufe | Ab Besuchen | Farbe |
|---|---|---|
| Dönerneuling | 0 | Grau |
| Dönerfreund | 5 | Braun |
| Dönerfan | 15 | Orange |
| Dönerprofi | 30 | Rot |
| Dönermeister | 60 | Lila |
| Dönerlegende | 100 | Gold |

### Erfolge

| Erfolg | Bedingung |
|---|---|
| First Bite | Erster Check-in |
| Kritiker | Erste Bewertung |
| Stammgast | 5× derselbe Laden |
| Entdecker | 10 verschiedene Läden |
| Kenner | 50 verschiedene Läden |
| Berlin Döner Tour | 5 Läden in Berlin |
| Hamburg Döner Tour | 5 Läden in Hamburg |
| Silber-Sammler | Stufe „Dönerfan“ erreicht |
| Gold-Sammler | Stufe „Dönermeister“ erreicht |
| Nachtschwärmer | Check-in nach 22 Uhr |
| Schmetterling | 5 Freunde |

Die Regeln liegen in `packages/doener_models` und sind dort getestet.

### Döner Wrapped

Jahresrückblick auf 5 Seiten mit wechselnden Farbverläufen: Besuche im Jahr, Lieblingsessen, Stammladen, entdeckte Läden, Zusammenfassung mit aktivstem Monat.

### Start

Der erste Tab, für den Umkreis von 10 km um den Standort (ohne Standort: Freiburg):

- Ganz oben die Freunde, die gerade essen
- Startaufgaben, bis sie erledigt sind: „Bewerte deinen Stammladen“ (führt zur Karte) und „Hol deine Freunde per QR-Code“
- „Top 3 hier“: nach gewichtetem Schnitt wie im Ranking. Gibt es zu wenige bewertete Läden, füllen die nächstgelegenen als „noch unbewertet“ auf
- „Gerade im Trend“: meiste Check-ins und Bewertungen der letzten 7 Tage, Check-ins zählen anonym
- Feed: Check-ins und Bewertungen der Freunde (orange hinterlegt) und die Bewertungen aller anderen im Umkreis, mit Namen. Check-ins sehen nur Freunde. Der Filter „Nur Freunde“ blendet die anderen aus, die eigene Aktivität steht im Profil

### Ranking

Ranking der Stadt laut Adresse; die Stadt ist die des nächsten bekannten Ladens im Umkreis von 20 km. Gerankt wird der Laden, umschaltbar nach Gesamt, Soße, Fleisch und Brot.

- Sortiert wird nach gewichtetem Schnitt: Jeder Laden startet mit drei Bewertungen in Höhe des Stadtschnitts (`weightedRating` in `packages/doener_models`). So schlägt eine einzelne 5 nicht viele 4,5er
- Angezeigt werden echter Schnitt und Anzahl, dazu die Freunde, die den Laden bewertet haben, mit ihrer Note

### Freunde

- Persönlicher Einladungslink samt QR-Code (Profil, Freunde-Liste, letzter Onboarding-Schritt): Wer ihn öffnet und sich anmeldet, ist sofort befreundet, eine offene Anfrage gilt damit als angenommen. Der Link lässt sich zurücksetzen.
- Ist die iOS-App installiert, öffnet der Link sie direkt (Universal Links, Domains in `app/ios/Runner/Runner.entitlements`). Ohne App führt er auf eine Einladungsseite (`/i/<code>`) mit Chat-Vorschau, von dort in die Web-App. Neue Accounts merken sich, über wessen Link sie kamen.
- Freunde per Namenssuche finden (ab 2 Zeichen); wer eine offene Anfrage zurückschickt, nimmt sie damit an

### Fehler melden

Für die Testphase liegt ein Käfer-Knopf über allen Screens, auch über Sheets. Er lässt sich verschieben. Ein Tipp fotografiert den Screen darunter (ohne die Google-Karte, native Ansichten erfasst Flutter nicht) und öffnet das Feedback-Formular mit diesem Screenshot. Das Formular gibt es auch unter Einstellungen → Feedback geben. Der Server speichert jede Meldung und mailt sie an `FEEDBACK_EMAIL`, mit dem Screenshot im Anhang. Eine Antwort auf die Mail geht direkt an den Tester.

---

## Architektur

```
app/                          Flutter-App (iOS, Android, Web)
├── lib/src/core/             ApiClient, Session, AppData (lokaler Store + Sync-Queue), Standort
├── lib/src/features/         auth, start, ranking, map, place, profile, social, settings, onboarding
└── lib/src/ui/               Theme und gemeinsame Widgets
server/                       Dart-API + Auslieferung der Web-App
├── lib/src/auth.dart         Magic-Link-Login, Sitzungen, Account
├── lib/src/places.dart       Läden, Bewertungen, Besuche, Top und Trend im Umkreis
├── lib/src/ranking.dart      Ranking pro Stadt
├── lib/src/social.dart       Feed, Live-Status, Freunde, Feedback, Ladenmeldungen
├── lib/src/google_places.dart
├── lib/src/db.dart           SQL-Migrationen (nur anhängen, nie ändern)
└── tool/seed_dev.dart        Test-Läden in Freiburg für Entwicklung ohne Google-Key
packages/doener_models/       Geteilte DTOs, Validierung, Ranking-Regel, Stempel/Erfolge/Essenstypen
```

**Prinzipien:**
- Offline-First: Die App zeigt alles aus dem lokalen Store. Eigene Besuche und Bewertungen warten in einer Queue, bis der Server sie bestätigt.
- Bei einem Netzwerkfehler versucht die App es später erneut, auch eine abgelaufene Sitzung verwirft keine Einträge. Nur was der Server endgültig ablehnt (z. B. ungültige Daten), wird verworfen.
- Der Server ist die Quelle der Wahrheit für den Account. Ein neues Gerät oder die Web-App holt sich Besuche und Bewertungen über `/me/*`.
- Favoriten und Notizen bleiben lokal auf dem Gerät.

### API (`/api/v1`)

| Methode | Pfad | Beschreibung |
|---|---|---|
| POST | `/auth/login` | Login-Code + Magic-Link per Mail schicken |
| POST | `/auth/verify` | Code oder Link-Token einlösen → Sitzung |
| POST | `/auth/logout` | Sitzung beenden |
| GET | `/auth/me` | Aktueller User |
| PATCH | `/users/me` | Anzeigename ändern |
| DELETE | `/users/me` | Account löschen |
| GET | `/places?minLat&minLon&maxLat&maxLon` | Läden im Kartenausschnitt |
| GET | `/places/top?lat&lon` | Beste im Umkreis von 10 km (gewichtet), mit unbewerteten aufgefüllt |
| GET | `/places/trending?lat&lon` | Meiste Check-ins und Bewertungen im Umkreis in 7 Tagen |
| GET | `/ranking?lat&lon&by` | Ranking der Stadt nach `overall`, `sauce`, `fleisch` oder `brot`, mit Freunden |
| GET | `/places/:placeId` | Laden (Google Place ID) |
| GET | `/places/:placeId/reviews` | Bewertungen des Ladens |
| GET | `/places/:placeId/summary` | Community-Zusammenfassung |
| PUT | `/places/:placeId/review` | Eigene Bewertung speichern |
| POST | `/places/:placeId/visits` | Check-in (idempotent über Client-ID) |
| GET | `/me/visits`, `/me/reviews`, `/me/places` | Eigene Daten |
| DELETE | `/me/live-status` | Live-Status beenden |
| GET | `/feed?cursor[&lat&lon]` | Check-ins und Bewertungen der Freunde, mit `lat`/`lon` auch alle Bewertungen im Umkreis (Keyset-Pagination) |
| GET | `/feed/live` | Live-Status der Freunde |
| GET | `/users/search?q` | Nutzer suchen |
| GET | `/friends` | Freundschaften |
| POST | `/friends/requests` | Anfrage senden |
| POST | `/friends/:id/accept` | Anfrage annehmen |
| DELETE | `/friends/:id` | Freundschaft entfernen |
| GET | `/me/invite` | Eigener Einladungslink |
| POST | `/me/invite/reset` | Neuer Einladungslink, der alte verfällt |
| GET | `/invites/:code` | Wer einlädt (ohne Login) |
| POST | `/invites/:code/accept` | Einladung annehmen → sofort befreundet |
| POST | `/feedback` | Feedback mit optionalem Screenshot |
| POST | `/shop-reports` | Fehlenden Laden melden |

Außerhalb von `/api/v1` liefert der Server unter `/i/:code` die Einladungsseite aus, unter `/.well-known/apple-app-site-association` die Freigabe, mit der iOS diese Links in der App öffnet.

---

## Entwicklung

Voraussetzung: [Flutter-SDK](https://docs.flutter.dev/get-started/install) (bringt Dart mit) und Docker. iOS-Builds brauchen macOS – das übernimmt die CI, entwickelt werden kann komplett unter Linux.

### Alles in einem

```bash
docker compose up --build        # App + API auf http://localhost:8080, Postgres auf :5434
```

Ohne `SMTP_HOST` landen die Login-Codes im Log (`docker compose logs app`).

### Einzeln (schneller beim Entwickeln)

```bash
docker compose up -d db

# Server
cd server
DB_PORT=5434 dart run tool/seed_dev.dart                    # Test-Läden, falls kein Google-Key
DB_PORT=5434 CORS_ORIGIN=http://localhost:5000 dart run bin/server.dart

# App im Browser
cd app
flutter run -d chrome --web-port 5000 --dart-define=API_BASE=http://localhost:8080/api/v1 \
  --dart-define=GOOGLE_MAPS_WEB_KEY=<Browser-Key>

# App im Android-Emulator
GOOGLE_MAPS_ANDROID_KEY=<Android-Key> flutter run -d emulator-5554 --dart-define=API_BASE=http://10.0.2.2:8080/api/v1
```

Für iOS den Key in `app/ios/Flutter/Secrets.xcconfig` eintragen (`GOOGLE_MAPS_IOS_KEY=…`, nicht eingecheckt).

In der App lässt sich die Backend-URL auch unter Einstellungen → Backend-URL umstellen.

### Tests

```bash
cd packages/doener_models && dart test
cd server && TEST_DB_PORT=5434 TEST_DB_USER=doener TEST_DB_PASSWORD=doener dart test   # legt DB doener_test neu an
cd app && flutter test
```

### Konfiguration

**Server (Umgebungsvariablen):**

| Variable | Standard | Zweck |
|---|---|---|
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | `localhost`, `5432`, `doener`, `doener`, `doener` | Postgres |
| `DB_TLS` | – | `require` für TLS zur Datenbank |
| `PORT` | `8080` | HTTP-Port |
| `PUBLIC_URL` | – | Basis für Magic-Links (`/login?token=…`) und Einladungslinks (`/i/…`); ohne steht nur der Code in der Mail |
| `GOOGLE_PLACES_API_KEY` | – | Ohne Key nur bereits bekannte Läden |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_SSL` | –, `587` | Mailversand; ohne Host stehen Codes im Log |
| `MAIL_FROM` | `Döner App <noreply@localhost>` | Absender |
| `WEB_DIR` | `web` | Web-Build, der unter `/` ausgeliefert wird |
| `CORS_ORIGIN` | – | Nur für lokale Web-Entwicklung |
| `APP_DOWNLOAD_URL` | – | Ziel von „App holen“ auf der Einladungsseite (z. B. öffentlicher TestFlight-Link); ohne nur Web-App |
| `FEEDBACK_EMAIL` | – | Empfänger der Tester-Meldungen; ohne werden sie nur gespeichert |

**App (`--dart-define`):**

| Variable | Standard | Zweck |
|---|---|---|
| `API_BASE` | Web: gleiche Domain; Mobil: Produktion | API-Adresse |
| `GOOGLE_MAPS_WEB_KEY` | – | Maps-JavaScript-Key für die Web-Version (ohne: keine Karte) |

**Google-Maps-Keys** (Google Cloud Console, je ein Key pro Plattform): „Maps SDK for iOS“ (eingeschränkt auf Bundle-ID `com.robinchoice.doener`), „Maps SDK for Android“ (Paketname + SHA-1 des Signaturzertifikats), „Maps JavaScript API“ (HTTP-Referrer der Web-Domain). Der Server braucht zusätzlich einen Key für „Places API (New)“.

---

## Deployment

| Workflow | Auslöser | Macht |
|---|---|---|
| `ci.yml` | PRs, Push auf `main` | Analyse + Tests für Models, Server (mit Postgres) und App |
| `deploy.yml` | Push auf `main` (`server/`, `app/`, `packages/`) | arm64-Image `ghcr.io/robinchoice/doener-api:<sha>` bauen, auf Coolify deployen |
| `mobile.yml` | Push auf `main` (`app/`, `packages/`), manuell | iOS → TestFlight, Android → signiertes App Bundle als Artefakt |

Das Image enthält Server und Web-App: Die API liegt unter `/api/v1`, alles andere ist die Web-App.

**Secrets:**
- Coolify: `COOLIFY_APP_UUID`, `COOLIFY_TOKEN`
- Google Maps: `GOOGLE_MAPS_IOS_KEY`, `GOOGLE_MAPS_ANDROID_KEY`, `GOOGLE_MAPS_WEB_KEY`
- iOS: `ASC_KEY_P8` (Base64), `ASC_KEY_ID`, `ASC_ISSUER_ID`
- Android: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` – ohne sie wird mit Debug-Keys signiert

Die Build-Nummer steigt pro Lauf automatisch (TestFlight lehnt doppelte ab).

---

## Design-Prinzipien

- **Orange als Akzentfarbe:** konsistent für alle interaktiven Elemente, Material 3, Hell- und Dunkelmodus
- **Offline-First:** Jede Aktion wird lokal gespeichert, bevor sie das Netzwerk berührt
- **Emoji als UI:** Essenstypen, Konfetti und Wrapped nutzen Emojis statt eigener Grafiken
- **FOSS, wo es geht:** Flutter, Dart, Postgres, Web-Ressourcen selbst gehostet statt vom CDN. Karte und Laden-Daten kommen von Google, weil OpenStreetMap deutlich weniger Döner-Läden und Öffnungszeiten kennt.

---

## Umbau

Beschlossen, aber noch nicht gebaut. Was fertig ist, wandert in die Abschnitte oben und fliegt hier raus.

### Leitlinie

- **Kern:** Bewertungen und das Ranking der Stadt, nicht Menge oder Spiel.
- **Zwei Ebenen:** Bewertungen (ab Phase 2 auch Fragen) sieht jeder im Umkreis von 10 km, mit Namen. Check-ins sehen nur Freunde. Freunde verbinden sich per QR-Code oder Einladungslink.
- **Nach dem Check-in:** Freunde bekommen einen Push mit dem Platz im Ranking („Tom isst gerade 🥙 bei X (Nr. 2 in Freiburg)“) und reagieren mit 🤤, 🥙 oder 🙋. Nach etwa 30 Minuten fragt die App „Wie war's bei X?“, als Benachrichtigung oder als Karte im Start. Wer den Laden schon bewertet hat, bekommt „Bleibt's bei 4,5?“.
- **Bewertung:** Soße, Fleisch, Brot (je 1–5, Unpassendes weglassen), optional Text und ein Foto. Die Gesamtnote ist der Durchschnitt, ohne manuelles Überschreiben. Bewerten darf jeder. Wer eingecheckt hat, bekommt das Häkchen „vor Ort“. Pro Person und Laden zählt die neueste Bewertung. Den Spruch unter dem Laden liefert ab Phase 2 die Bewertung mit den meisten Upvotes.
- **Push:** Check-ins von Freunden (pro Person höchstens alle 3 Stunden), Antworten auf eigene Beiträge und die Bewertungserinnerung. Neue Fragen gehen nur an Kenner (ab 5 bewerteten Läden in der Stadt), höchstens eine am Tag. Upvotes und Ranking-Änderungen zeigt nur die App. Jede Art ist abschaltbar, Freunde einzeln stummschaltbar.
- **Belohnung:** eine Stufe nach bewerteten Läden (bisherige Stufen-Namen) neben dem Namen, ab Phase 2 mit den Upvotes. Wrapped gibt es nur im Dezember.
- **Fällt weg:** Erfolge, Stempelkarte, Konsum-Statistik, private Notizen und „Was macht den Laden besonders?“.
- **Profil:** öffentlich mit Name, Stufe und Bewertungen. Freunde sehen zusätzlich die Check-ins.
- **Texte:** Einladung „Welcher Döner ist der beste in [Stadt]? Die Döner-App weiß es, und du siehst, wo ich gerade esse: [Link]“, App-Store-Untertitel „Der beste Döner deiner Stadt“.

### Phase 1 – Bester Döner der Stadt

- Neue Bewertung mit Foto und Häkchen „vor Ort“
- Erinnerung nach dem Check-in („Wie war's bei X?“)
- Push für Check-ins von Freunden: iOS über APNs, dazu Web Push
- Öffentliches Profil mit Stufe, Wegfallendes entfernen
- Universal Links auch für den Magic-Link (bis dahin: Code eintippen)
- Melden und Blockieren (Pflicht für die Stores, spätestens mit den Fotos)

### Phase 2 – Community

- Fragen an den Umkreis, Antworten mit verlinktem Laden, Kommentare
- Up- und Downvotes, ab −5 ausgeblendet, Upvotes neben dem Namen
- Kenner-Push für neue Fragen, Kenner des Monats 👑 (meiste Upvotes in der Stadt)
- Favoriten werden zur Merkliste „Will ich probieren“

### Messen

Skript über die Datenbank, Ziele nach 4 Wochen:
- Anteil der Check-ins mit Bewertung danach
- Läden der Stadt mit mindestens 3 Bewertungen
- Ab Phase 2: Anteil der Fragen mit Antwort binnen 24 Stunden
- K-Faktor über Einladungslinks

### Voraussetzungen und Offenes

- APNs-Schlüssel im Apple-Developer-Konto (für Push) und eine Subdomain ohne „api“ für die Links (dann auch in `Runner.entitlements` und im Android-Manifest eintragen)
- Upload ins Play Store (bisher nur das App Bundle als Artefakt)
- Android-App-Links: Der Intent-Filter steht, es fehlt `/.well-known/assetlinks.json` mit dem SHA-256 des Release-Schlüssels. Bis dahin öffnen Einladungslinks auf Android den Browser, weil die CI ohne Keystore-Secrets mit wechselnden Debug-Keys signiert.
- Später: Bezirke für Großstädte. Falls Fakes auftauchen, zählen nur noch Bewertungen mit Häkchen voll.
