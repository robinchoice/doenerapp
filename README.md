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
- Registrierung geschlossen wie in starter („Registrierung öffnen“): Bestehende Konten melden sich an, neue nur über `SIGNUP_ALLOWLIST`, den Einladungslink eines Freundes oder eine Einladung von Robin (Profil → Tester einladen, für `ADMIN_EMAILS`). Wer vor der Schließung (15.10.2026, 16:30) über die Landingpage um einen Test gebeten hat, kommt ebenfalls herein, bis die Anfrage nach 90 Tagen gelöscht ist. Fremde bekommen eine Meldung auf Deutsch und Englisch, es geht keine Mail raus. Geöffnet wird mit `SIGNUP_OPEN=true`, das entscheidet Robin.

---

## Features

### Karte

Die Karte lädt Dönerläden für den sichtbaren Ausschnitt (nur bis 0,5° Span). Der Server fragt Google pro Kachel (0,03°) höchstens alle 25 Tage ab, auch leere Kacheln werden gemerkt. Das hält die Google-Kosten klein. Erkannt werden Läden über den Namen (Döner, Kebap, Dürüm, Yufka …) oder den Google-Typ (z. B. türkisches Restaurant).

Google erlaubt, Laden-Details höchstens 30 Tage zu speichern (nur die Place ID unbegrenzt) und Places-Daten nur auf Google-Karten zu zeigen. Deshalb: Karte von Google Maps, ein täglicher Job auf dem Server frischt Läden mit Besuchen oder Bewertungen auf und löscht ungenutzte nach 30 Tagen, die App verwirft ihren lokalen Cache ebenso. Listen ohne Karte tragen den Hinweis „Ortsdaten: Google Maps“.

- Pins im Produktton, besuchte Läden grün, Favoriten pink; im Dunkelmodus ist die Karte dunkel; fremde Geschäfts-POIs sind ausgeblendet
- Lupe oben rechts: Suche in allen Läden, die die App schon kennt; daneben der Favoriten-Filter per Herz
- „Laden fehlt?“ oben links schickt eine Meldung samt Kartenposition an den Server
- Mit Ernährung „Vegan“ verschwinden Läden, in denen die Mehrheit nichts Veganes gefunden hat. Bei Vegetarisch und Vegan sind Läden blass, von denen noch niemand Passendes bewertet hat
- Angekündigte Eröffnungen (Google-Status `FUTURE_OPENING`) zeigt die Karte noch nicht. Der tägliche Job prüft ab dem angekündigten Tag, ob der Laden offen ist, und merkt sich dann das Eröffnungsdatum

### Check-In

Eingecheckt wird nur vor Ort, über den 🥙-Knopf in der Mitte der Tab-Leiste. Er trägt den Verlauf, sobald ein Laden höchstens 150 m entfernt ist, sonst ist er grau. Dafür lädt die App die Läden rund um den Standort und verfolgt ihn, solange sie offen ist. Ein Tipp auf den grauen Knopf fragt nach dem Standort, falls er noch nicht freigegeben ist, und lädt die Läden in der Nähe neu. Den Abstand prüft nur die App: Koordinaten ließen sich ohnehin fälschen, deshalb verzichtet der Server darauf, solange keine Fakes auftauchen.

Danach kommt ein Drehrad mit den Essenstypen, die zur Ernährung passen (Döner, Yufka, Lahmacun, Teller, Pommes, Falafel, veganer Döner, Halloumi, Pizza, Pide, Seele), das oberste Symbol ist ausgewählt. Stehen mehrere Läden nebeneinander, wählt man vorher den richtigen aus. Nach dem Check-in regnet es Emojis des gewählten Essens. Einen Kommentar gibt es nicht.

- Check-ins werden sofort lokal gespeichert und über eine Sync-Queue an den Server geschickt
- Die ID erzeugt der Client, deshalb entstehen bei Wiederholungen keine doppelten Besuche
- Ein Check-in setzt für eine Stunde den Live-Status („isst gerade bei …“), aber nur wenn er wirklich gerade passiert
- Eine halbe Stunde danach fragt eine lokale Benachrichtigung „Wie war's bei X?“, wer den Laden schon bewertet hat, bekommt „Bleibt's bei 4,5?“. Ein Tipp öffnet den Bewertungsbogen. Wer vorher bewertet, wird nicht gefragt, ein späterer Check-in ersetzt die Erinnerung, und in den Einstellungen lässt sie sich abschalten. Dafür braucht es weder Server noch APNs
- Dieselbe Frage steht als Karte auf Start, auf allen Geräten und im Browser (der keine Benachrichtigungen planen kann): je Laden mit einem Check-in der letzten 14 Tage, der seitdem nicht bewertet wurde, ab einer halben Stunde nach dem Check-in, höchstens drei. Grundlage sind die synchronisierten eigenen Check-ins und Bewertungen, eine geschlossene Karte bleibt auf diesem Gerät zu

### Bewertungen

Ein Bogen, alle Punkte 1–5 in halben Schritten und optional. Ein Tipp auf die linke Hälfte eines Bestecks gibt den halben Punkt. Oben der Döner mit Soße, Fleisch und Brot. Die Gesamtnote ist ihr Durchschnitt, auf halbe Punkte gerundet, ohne manuelles Überschreiben. Sie zählt erst, wenn Soße oder Fleisch benotet ist, Brot allein ist keine Döner-Note. Darunter:

- „Was gab's noch?“: Falafel, Halloumi, Pizza, Pide, Lahmacun, Seele. Ein Tipp öffnet die Zeile, jedes Gericht hat eine eigene Rangliste und zählt nicht in die Gesamtnote
- „Vegane Optionen?“ (Ja/Nein/Weiß nicht): Bei Ja lassen sich veganer Döner (Seitan oder Soja), vegane Soße und Hummus bewerten. „Nein“ zeigt der Laden als „Nichts Veganes“
- „Selbstgemachter Ayran?“: Bewertet wird nur selbstgemachter, „gekauft“ steht trotzdem am Laden
- Expertenmodus (Einstellungen): fragt ab, was in „mit allem“ steckt (Salat, Besonderheiten wie Granatapfelkerne oder Mais, Soßen), dazu Fleisch, Spieß (selbst gesteckt oder Fertigspieß) und Brot. Vorausgefüllt mit dem, was andere angegeben haben
- Eine Bewertung pro Nutzer und Laden, eine neue ersetzt die alte. Die Angaben (vegan, Ayran, Zutaten) hängen an der Bewertung, pro Laden zählt die Mehrheit
- Optional ein Foto (Kamera oder Galerie, JPEG, PNG oder WebP bis 3 MB). Es bleibt beim Bearbeiten, bis es ersetzt oder entfernt wird, und wartet wie die Bewertung offline in der Queue. Der Server speichert es in Postgres, jedes neue Foto bekommt eine neue ID und ist darüber dauerhaft cachebar
- Wer im Laden schon einmal eingecheckt hat, bekommt das Häkchen „vor Ort“, wer an mindestens drei verschiedenen Tagen eingecheckt hat, das Abzeichen „Stammgast“ (`regularVisits` in `packages/doener_models`). Der Server leitet beides beim Lesen aus den Check-ins ab und zählt die Tage nach dem Eingang beim Server (deutsche Zeit), zurückdatierte Check-ins zählen also nicht extra
- Durchschnitt und Anzahl berechnet der Server beim Lesen. Die Noten einer Bewertung (Döner, ohne Fleisch, vegan) leitet er beim Speichern aus den Punkten ab (`Diet.score` in `packages/doener_models`)
- In der Laden-Ansicht: Chips für vegane Optionen, Ayran und Besonderheiten (für alle sichtbar), „Was es hier gibt“ mit den Durchschnitten aller Punkte, im Expertenmodus „Mit allem heißt hier …“, dazu die eigene Bewertung und die der anderen, die von Freunden zuerst. Ein Info-Knopf dort und im Ranking erklärt, wer bewertet, was „vor Ort“ und „Stammgast“ prüfen und wie das Ranking sortiert (Pflichtangabe nach § 5b UWG)
- Aushang für den Laden: Unten in der Laden-Ansicht öffnet „Aushang zum Bewerten“ eine Druckseite (`/aushang/<placeId>`) mit QR-Code. Er führt auf `/b/<placeId>`: Mit installierter App öffnet sich direkt deren Bewertungsbogen, sonst eine Seite, die in die Web-App führt (`/app?review=<placeId>`). Auch ohne Konto bleibt der Wunsch über Onboarding und Login erhalten. Ist der Laden inzwischen aus dem 30-Tage-Cache gefallen, zeigt `/b/` ihn ohne Namen, und `/places/:placeId` lädt ihn für angemeldete Nutzer einzeln bei Google nach (nur offene Döner-Läden)

### Ernährung

In den Einstellungen: Alles, Vegetarisch oder Vegan. Gespeichert am Account, gilt also auch in der Web-App. Bewertung, Laden, Ranking, Start, Karte und Check-in zeigen dann nur, was zur Ernährung passt. Statt der Gesamtnote zählt eine eigene Note:

| Ernährung | Note | Durchschnitt aus | zählt, sobald bewertet ist |
|---|---|---|---|
| Alles | Gesamt | Soße, Fleisch, Brot | Soße oder Fleisch |
| Vegetarisch | Ohne Fleisch | Falafel, Halloumi, veganer Döner, Soße, Brot | Falafel, Halloumi oder veganer Döner |
| Vegan | Vegan | Falafel, veganer Döner, vegane Soße, Hummus, Brot | eines davon außer Brot |

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

Jahresrückblick auf 5 Seiten auf dunklem Grund: Besuche im Jahr, Lieblingsessen, Stammladen, entdeckte Läden, Zusammenfassung mit aktivstem Monat.

### Start

Der erste Tab, für den Umkreis von 10 km um den Standort (ohne Standort: Freiburg):

- Ganz oben die Freunde, die gerade essen
- Startaufgaben, bis sie erledigt sind: „Bewerte deinen Stammladen“ (führt zur Karte) und „Hol deine Freunde per QR-Code“
- „Neu in [Stadt]“: Läden, die in den letzten 30 Tagen aufgemacht haben, und Eröffnungen, die Google angekündigt hat („Bald: … Laut Google am 15. Oktober“)
- „Top 3 hier“: nach gewichtetem Schnitt der Note zur Ernährung, wie im Ranking. Gibt es zu wenige bewertete Läden, füllen die nächstgelegenen als „noch unbewertet“ auf
- „Gerade im Trend“: meiste Check-ins und Bewertungen der letzten 7 Tage, Check-ins zählen anonym
- Feed: Check-ins und Bewertungen der Freunde (mit Linie in der Akzentfarbe) und die Bewertungen aller anderen im Umkreis, mit Namen. Check-ins sehen nur Freunde. Der Filter „Nur Freunde“ blendet die anderen aus, die eigene Aktivität steht im Profil

### Ranking

Ranking der Stadt laut Adresse; die Stadt ist die des nächsten bekannten Ladens im Umkreis von 20 km. Gerankt wird der Laden, umschaltbar per Chips: zuerst die Note zur Ernährung, dann einzelne Punkte (bei „Alles“ Soße, Fleisch, Brot, Falafel, Halloumi, Vegan, Pizza, Pide, Lahmacun, Seele, Ayran).

- Sortiert wird nach gewichtetem Schnitt: Jeder Laden startet mit drei Bewertungen in Höhe des Stadtschnitts (`weightedRating` in `packages/doener_models`). So schlägt eine einzelne 5 nicht viele 4,5er
- Angezeigt werden echter Schnitt und Anzahl, dazu die Freunde, die den Laden bewertet haben, mit ihrer Note

### Freunde

- Persönlicher Einladungslink samt QR-Code (Profil, Freunde-Liste, letzter Onboarding-Schritt): Wer ihn öffnet und sich anmeldet, ist sofort befreundet, eine offene Anfrage gilt damit als angenommen. Der Link lässt sich zurücksetzen.
- Ist die iOS-App installiert, öffnet der Link sie direkt (Universal Links, Domains in `app/ios/Runner/Runner.entitlements`). Ohne App führt er auf eine Einladungsseite (`/i/<code>`) mit Chat-Vorschau, von dort in die Web-App. Neue Accounts merken sich, über wessen Link sie kamen.
- Freunde per Namenssuche finden (ab 2 Zeichen); wer eine offene Anfrage zurückschickt, nimmt sie damit an

### Melden und Blockieren

Pflicht für die Stores, weil Bewertungen mit Text, Foto und Namen für alle im Umkreis sichtbar sind. Das ⋮ an fremden Bewertungen (Laden, Start) und an Check-ins von Freunden bietet:
- **Bewertung melden** mit Grund und optionalem Hinweis. Der Server speichert die Meldung (eine pro Person und Bewertung) und mailt sie an `FEEDBACK_EMAIL`, Antworten gehen an die meldende Person
- **Blockieren**: Beide sehen die Bewertungen des anderen nicht mehr, finden sich nicht in der Suche und können sich nicht befreunden, eine Freundschaft endet. Ins Ranking zählen die Bewertungen weiter. Freigeben unter Einstellungen → Blockierte Nutzer
- **Bewertung entfernen** nur für Admins (`ADMIN_EMAILS`), so wird eine gemeldete Bewertung gelöscht

### Fehler melden

Für die Testphase liegt ein Käfer-Knopf über allen Screens, auch über Sheets. Er lässt sich verschieben. Ein Tipp fotografiert den Screen darunter (ohne die Google-Karte, native Ansichten erfasst Flutter nicht) und öffnet das Feedback-Formular mit diesem Screenshot. Das Formular gibt es auch unter Einstellungen → Feedback geben. Der Server speichert jede Meldung und mailt sie an `FEEDBACK_EMAIL`, mit dem Screenshot im Anhang. Eine Antwort auf die Mail geht direkt an den Tester.

### Landingpage

`/` (Deutsch) und `/en` (Englisch) zeigen eine statische Seite vom Server (`server/lib/src/landing.dart`), die Web-App läuft unter `/app`. Wer im Browser schon angemeldet ist oder mit Parametern kommt (`?invite=…`), wird sofort nach `/app` weitergeleitet. Die Rangliste im Handy auf der Seite ist ein Beispiel, keine echten Daten.

Über das Formular fragt man den Test an: iPhone (TestFlight) oder Android (Play-Test) und eine E-Mail. Der Server speichert die Anfrage 90 Tage, einmal pro Adresse und Plattform, und mailt sie an `FEEDBACK_EMAIL`. Freigeschaltet wird von Hand: iOS in App Store Connect unter TestFlight, Android in der Play Console unter Interner Test, dazu den Link per Antwort auf die Mail schicken.

---

## Architektur

```
app/                          Flutter-App (iOS, Android, Web)
├── lib/src/core/             ApiClient, Session, AppData (lokaler Store + Sync-Queue), Standort
├── lib/src/features/         auth, start, ranking, map, place, profile, social, settings, onboarding
└── lib/src/ui/               Theme und gemeinsame Widgets
server/                       Dart-API + Auslieferung der Web-App
├── lib/src/auth.dart         Magic-Link-Login, Sitzungen, Account
├── lib/src/places.dart       Läden, Bewertungen, Besuche, Top, Trend und Neueröffnungen im Umkreis
├── lib/src/ranking.dart      Ranking pro Stadt
├── lib/src/social.dart       Feed, Live-Status, Freunde, Feedback, Ladenmeldungen
├── lib/src/google_places.dart
├── lib/src/db.dart           SQL-Migrationen (nur anhängen, nie ändern)
└── tool/seed_dev.dart        Test-Läden in Freiburg für Entwicklung ohne Google-Key
packages/doener_models/       Geteilte DTOs, Validierung, Bewertungspunkte und Ernährung (`menu.dart`), Ranking-Regel, Stempel/Erfolge/Essenstypen
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
| POST | `/auth/invite` | Admin legt ein Tester-Konto an und mailt den Login-Code |
| POST | `/auth/logout` | Sitzung beenden |
| GET | `/auth/me` | Aktueller User mit Ernährung und Expertenmodus |
| PATCH | `/users/me` | Anzeigename, Ernährung oder Expertenmodus ändern |
| DELETE | `/users/me` | Account löschen |
| GET | `/places?minLat&minLon&maxLat&maxLon` | Läden im Kartenausschnitt |
| GET | `/places/top?lat&lon[&by]` | Beste im Umkreis von 10 km (gewichtet) nach `overall`, `vegetarian` oder `vegan`, mit unbewerteten aufgefüllt |
| GET | `/places/new?lat&lon` | Im Umkreis neu eröffnete (30 Tage) und von Google angekündigte Läden |
| GET | `/places/trending?lat&lon` | Meiste Check-ins und Bewertungen im Umkreis in 7 Tagen |
| GET | `/ranking?lat&lon&by` | Ranking der Stadt nach `overall`, `vegetarian`, `vegan` oder einem Punkt (`sauce`, `falafel`, `ayran` …), mit Freunden |
| GET | `/places/:placeId` | Laden (Google Place ID); fehlt er im Cache, lädt der Server ihn für Angemeldete bei Google nach |
| GET | `/places/:placeId/reviews` | Bewertungen des Ladens, angemeldet ohne die von Blockierten |
| GET | `/places/:placeId/summary` | Durchschnitt je Punkt, Ayran und was „mit allem“ heißt |
| PUT | `/places/:placeId/review` | Eigene Bewertung speichern, optional mit Foto (`photoBase64`) oder ohne das bisherige (`removePhoto`) |
| GET | `/photos/:id` | Foto einer Bewertung (ohne Login) |
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
| POST | `/reviews/:id/report` | Bewertung melden |
| DELETE | `/reviews/:id` | Bewertung entfernen (Admins) |
| GET | `/me/blocks` | Blockierte Nutzer |
| PUT, DELETE | `/me/blocks/:userId` | Blockieren, freigeben |
| POST | `/tester-requests` | Testanfrage von der Landingpage, ohne Login |

Außerhalb von `/api/v1` liefert der Server unter `/i/:code` die Einladungsseite aus, unter `/b/:placeId` die Bewertungsseite eines Ladens, unter `/aushang/:placeId` dessen Aushang mit QR-Code und unter `/.well-known/apple-app-site-association` die Freigabe, mit der iOS Einladungs- und Bewertungslinks in der App öffnet.

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
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_SSL` | –, `587` | Mailversand; ohne Host stehen Codes im Log, in Produktion startet der Server dann nicht |
| `APP_ENV` | – (`production` im Image) | `production` macht `SMTP_HOST` zur Pflicht; die lokale Compose setzt `development` |
| `APP_VERSION` | `dev` (Commit im Image) | Von `/api/v1/health` als `revision` gemeldet |
| `MAIL_FROM` | `Döner App <noreply@localhost>` | Absender |
| `WEB_DIR` | `web` | Web-Build, der unter `/` ausgeliefert wird |
| `CORS_ORIGIN` | – | Nur für lokale Web-Entwicklung |
| `APP_DOWNLOAD_URL` | – | Ziel von „App holen“ auf der Einladungsseite (z. B. öffentlicher TestFlight-Link); ohne nur Web-App |
| `FEEDBACK_EMAIL` | – | Empfänger der Tester-Meldungen und Testanfragen; ohne werden sie nur gespeichert |
| `SIGNUP_OPEN` | – (lokale Compose: `true`) | `true` öffnet die Registrierung für alle, nur nach Robins Go |
| `SIGNUP_ALLOWLIST` | – | Kommagetrennte Adressen, die ohne Einladung ein neues Konto bekommen |
| `ADMIN_EMAILS` | – | Kommagetrennte Adressen, die Tester einladen (robin@pleasance.org, nie admin@pleasance.org) |

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
| `mobile.yml` | Tags `v*`, manuell | iOS → TestFlight, Android → App Bundle als Artefakt und in den internen Play-Test |

Das Image enthält Server und Web-App: Die API liegt unter `/api/v1`, die Landingpage unter `/` und `/en`, alles andere ist die Web-App (`/app`).

**Secrets:**
- Coolify: `COOLIFY_UUID`, `COOLIFY_TOKEN`
- Google Maps: `GOOGLE_MAPS_IOS_KEY`, `GOOGLE_MAPS_ANDROID_KEY`, `GOOGLE_MAPS_WEB_KEY`
- iOS: `ASC_KEY_P8` (Base64), `ASC_KEY_ID`, `ASC_ISSUER_ID`, dazu `IOS_DEV_CERTIFICATE` (Base64-PKCS12 eines festen „Apple Development“-Zertifikats, läuft am 04.10.2027 ab) und `IOS_DEV_CERTIFICATE_PASSWORD`. Ohne festes Zertifikat legt Xcode pro Lauf ein neues an, bis die Zertifikatsgrenze des Teams erreicht ist.
- Android: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` – ohne sie wird mit Debug-Keys signiert
- Play: `PLAY_SERVICE_ACCOUNT_JSON` (Dienstkonto mit Release-Rechten für die App in der Play Console) – ohne es bleibt es beim Artefakt. Die API nimmt erst Uploads an, wenn das erste App Bundle von Hand hochgeladen wurde

Die Build-Nummer steigt pro Lauf automatisch (TestFlight lehnt doppelte ab).

---

## Design-Prinzipien

- **Pleasance-Familie:** Gestaltung nach `DESIGN.md` im Starter (`~/dev/starter`). Stufe 3, Ausschnitt 2,55–3,20 (`appBand` in `app/lib/src/ui/brand.dart`). Der Verlauf sitzt nur auf Handlungsflächen (Hauptbuttons, Einchecken, aktiver Tab, Fortschritt), Bricolage Grotesque (selbst gehostet) für Titel, Plätze und Noten, Listen mit Haarlinien. Hell- und Dunkelmodus folgen dem System, ab 900 px Breite gibt es eine Navigationsleiste links
- **Offline-First:** Jede Aktion wird lokal gespeichert, bevor sie das Netzwerk berührt
- **Emoji als UI:** Essenstypen, Konfetti und Wrapped nutzen Emojis statt eigener Grafiken
- **FOSS, wo es geht:** Flutter, Dart, Postgres, Web-Ressourcen selbst gehostet statt vom CDN. Karte und Laden-Daten kommen von Google, weil OpenStreetMap deutlich weniger Döner-Läden und Öffnungszeiten kennt.

---

## Umbau

Beschlossen, aber noch nicht gebaut. Was fertig ist, wandert in die Abschnitte oben und fliegt hier raus.

### Leitlinie

- **Kern:** Bewertungen und das Ranking der Stadt, nicht Menge oder Spiel.
- **Zwei Ebenen:** Bewertungen (ab Phase 2 auch Fragen) sieht jeder im Umkreis von 10 km, mit Namen. Check-ins sehen nur Freunde. Freunde verbinden sich per QR-Code oder Einladungslink.
- **Nach dem Check-in:** Freunde bekommen einen Push mit dem Platz im Ranking („Tom isst gerade 🥙 bei X (Nr. 2 in Freiburg)“) und reagieren mit 🤤, 🥙 oder 🙋. Nach etwa 30 Minuten fragt die App „Wie war's bei X?“. Wer den Laden schon bewertet hat, bekommt „Bleibt's bei 4,5?“.
- **Bewertung:** optional mit Foto. Bewerten darf jeder, wer eingecheckt hat, bekommt das Häkchen „vor Ort“. Den Spruch unter dem Laden liefert ab Phase 2 die Bewertung mit den meisten Upvotes.
- **Push nur für Freunde und neue Läden:** Check-ins von Freunden (pro Person höchstens alle 3 Stunden) und „Neuer Döner hat in Freiburg aufgemacht“ an alle in der Stadt, sobald ein angekündigter Laden offen ist. Dazu als Ausnahme die eigene Bewertungserinnerung. Antworten, neue Fragen, Upvotes und Ranking-Änderungen zeigt nur die App. Jede Art ist abschaltbar, Freunde einzeln stummschaltbar.
- **Belohnung:** eine Stufe nach bewerteten Läden (bisherige Stufen-Namen) neben dem Namen, ab Phase 2 mit den Upvotes. Wrapped gibt es nur im Dezember.
- **Fällt weg:** Erfolge, Stempelkarte, Konsum-Statistik und private Notizen.
- **Profil:** öffentlich mit Name, Stufe und Bewertungen. Freunde sehen zusätzlich die Check-ins.
- **Texte:** Einladung „Welcher Döner ist der beste in [Stadt]? Die Döner-App weiß es, und du siehst, wo ich gerade esse: [Link]“, App-Store-Untertitel „Der beste Döner deiner Stadt“.

### Phase 1 – Bester Döner der Stadt

- Push für Check-ins von Freunden und neue Läden, jeweils mit Schalter in den Einstellungen: iOS über APNs, dazu Web Push. Für „neuer Laden“ merkt sich der Server die Stadt des Accounts
- Öffentliches Profil mit Stufe, Wegfallendes entfernen
- Universal Links auch für den Magic-Link (bis dahin: Code eintippen)

### Phase 2 – Community

- Fragen an den Umkreis, Antworten mit verlinktem Laden, Kommentare
- Up- und Downvotes, ab −5 ausgeblendet, Upvotes neben dem Namen
- Kenner des Monats 👑 (meiste Upvotes in der Stadt)
- Favoriten werden zur Merkliste „Will ich probieren“

### Messen

Skript über die Datenbank, Ziele nach 4 Wochen:
- Anteil der Check-ins mit Bewertung danach
- Läden der Stadt mit mindestens 3 Bewertungen
- Ab Phase 2: Anteil der Fragen mit Antwort binnen 24 Stunden
- K-Faktor über Einladungslinks

### Voraussetzungen und Offenes

- APNs-Schlüssel im Apple-Developer-Konto (für Push) und ab 1.0 eine eigene Domain unabhängig von pleasance.org für Landingpage, Web-App und Links (dann auch in `Runner.entitlements` und im Android-Manifest eintragen)
- Android-App-Links: Der Intent-Filter steht, es fehlt `/.well-known/assetlinks.json` mit dem SHA-256 des Release-Schlüssels. Bis dahin öffnen Einladungs- und Bewertungslinks auf Android den Browser, weil die CI ohne Keystore-Secrets mit wechselnden Debug-Keys signiert.
- Später: Bezirke für Großstädte. Falls Fakes auftauchen, zählen nur noch Bewertungen mit Häkchen voll.
