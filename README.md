# Döner-App 🥙

**Der beste Döner der Stadt – empfohlen von Leuten in deiner Umgebung.**

Eine lokale Döner-Community für iOS, Android und Web aus einer Codebase. Wer in der Nähe Döner isst, bewertet die Läden nach Soße, Fleisch, Salat und Brot. Daraus entstehen das Ranking der Stadt und die Trends im Umkreis. Freunde verbinden sich per QR-Code und sehen, wo der andere gerade isst.

Die App wird gerade auf diese Ausrichtung umgebaut. Was beschlossen, aber noch nicht gebaut ist, steht unter [Umbau](#umbau). Alle anderen Abschnitte beschreiben den Stand im Code.

---

## Überblick

Die Döner-App zeigt die besten Döner-Läden der Umgebung und das Ranking der Stadt, gebildet aus den Bewertungen nach Soße/Fleisch/Salat/Brot. Ein Check-in vor Ort zeigt den Freunden, wo man gerade isst. Jedes Profil ist öffentlich: Stufe, Bewertungen und die persönliche Bestenliste.

**Stack:**
- App: Flutter (iOS, Android, Web), Google Maps (google_maps_flutter), sembast als lokaler Store
- Server: Dart (shelf), PostgreSQL – liefert auch die Web-App aus
- Geteilt: `packages/doener_models` – DTOs, Validierung und Gamification-Regeln für App und Server
- Läden: Google Places API (New), serverseitig abgefragt und gecacht
- Login: E-Mail-Code bzw. Magic-Link, kein Passwort; Pflicht, samt eigenem Anzeigenamen statt „Döner-Fan-1234“
- Registrierung geschlossen wie in starter („Registrierung öffnen“): Bestehende Konten melden sich an, neue nur über `SIGNUP_ALLOWLIST`, eine Einladung von Robin (Profil → Tester, für `ADMIN_EMAILS`) oder als Admin selbst, sonst könnte niemand einladen. Der Einladungslink eines Freundes verbindet nur bestehende Konten, so können Tester niemanden weiter hereinholen (Robins Entscheidung vom 15.10.2026). Wer kein Konto hat, bewirbt sich auf der Landingpage. Dorthin führen die Einladungsseite, die Bewertungsseite `/b/` und die Meldung beim Login; die Bewerbung merkt sich, über wessen Link sie kam. Wer vor der Schließung (15.10.2026, 16:30) über die Landingpage um einen Test gebeten hat, kommt ebenfalls herein, bis die Anfrage nach 90 Tagen gelöscht ist. Fremde bekommen eine Meldung auf Deutsch und Englisch, es geht keine Mail raus. Geöffnet wird mit `SIGNUP_OPEN=true`, das entscheidet Robin.
- Freischalten: Unter Profil → Tester sieht Robin die Bewerbungen. „Freischalten“ legt das Konto an, schickt die Login-Mail und bei iPhones die TestFlight-Einladung in die externe Gruppe „Erste Tester“ (App Store Connect API, `ASC_*`). Wer über den Link eines Freundes kam, ist danach mit ihm befreundet. Ablehnen löscht die Anfrage ohne Mail. Android-Tester bekommen die APK bzw. später den Play-Test-Link per Antwort auf die Anfrage-Mail
- Neue iOS-Builds: Nur Release-Tags `v*` gehen an die externen Tester, weil jede Zuordnung allen eine Mail schickt. Der Job `testflight-release` in `mobile.yml` wartet, bis Apple den Build verarbeitet hat, gibt ihn an „Erste Tester“ und reicht ihn zur Beta-Prüfung ein (`server/tool/testflight_release.dart`). Weitere Builds einer freigegebenen Version lässt Apple sofort durch, TestFlight aktualisiert bei den Testern von selbst.

---

## Features

### Karte

Die Karte lädt Dönerläden für den sichtbaren Ausschnitt (nur bis 0,5° Span). Der Server fragt Google pro Kachel (0,03°) höchstens alle 25 Tage ab, auch leere Kacheln werden gemerkt. Das hält die Google-Kosten klein.

Wichtige Gebiete sucht der Server vorab, ohne dass jemand dort war: die Städte über 100.000 Einwohner, das Saarland und Baden-Württemberg (`server/lib/src/prefetch.dart`). Ein täglicher Job sucht sie in Blöcken von 8 × 8 Kacheln, mit höchstens 110 Anfragen pro Lauf. Liefert ein Block mehr Läden, als eine Suche zurückgibt (60), sucht er dessen Viertel einzeln. Gesuchte Blöcke zählen wie Kacheln 25 Tage, danach beginnt die Runde von vorn.

Google-Kosten: Die Suchen fragen keine Öffnungszeiten ab, damit bleiben sie in der Stufe „Text Search Pro“ (5.000 Anfragen im Monat frei statt 1.000). Öffnungszeiten holt `GET /places/:placeId` per Place Details, wenn jemand einen Laden öffnet, höchstens alle 25 Tage. Die Tagesquoten im Google-Projekt begrenzen beides hart (infra.md). Erkannt werden Läden über den Namen (Döner, Kebap, Dürüm, Yufka …) oder den Google-Typ (z. B. türkisches Restaurant).

Google erlaubt, Laden-Details höchstens 30 Tage zu speichern (nur die Place ID unbegrenzt) und Places-Daten nur auf Google-Karten zu zeigen. Deshalb: Karte von Google Maps, ein täglicher Job auf dem Server frischt Läden mit Besuchen oder Bewertungen samt Öffnungszeiten auf und löscht ungenutzte nach 30 Tagen, Öffnungszeiten ebenso, die App verwirft ihren lokalen Cache ebenso. Listen ohne Karte tragen den Hinweis „Ortsdaten: Google Maps“.

- Bewertete Läden zeigen ihre Note (je nach Ernährung) als Pin, ab Zoom 15 mit Namen daneben wie bei Google Maps; unbewertete sind kleine Punkte. Pins im Produktton, besuchte Läden grün, Favoriten pink, bessere Läden und Favoriten liegen oben; im Dunkelmodus ist die Karte dunkel; fremde Geschäfts-POIs sind ausgeblendet
- „Laden suchen“ oben: Suche nach Namen in den Läden auf dem Gerät und in allen, die der Server kennt, die nächsten zuerst; daneben der Favoriten-Filter per Herz
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

Ein Bogen, alle Punkte 1–5 in halben Schritten und optional. Ein Tipp auf die linke Hälfte eines Bestecks gibt den halben Punkt. Oben der Döner mit Soße, Fleisch, Salat und Brot. Die Gesamtnote ist ihr Durchschnitt, auf halbe Punkte gerundet, ohne manuelles Überschreiben. Sie zählt erst, wenn Soße oder Fleisch benotet ist, Brot oder Salat allein sind keine Döner-Note. Darunter der Preis in € (1–30 €, optional), der Laden zeigt den Median aller Angaben („Meist 7,50 €“). Darunter:

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
| Alles | Gesamt | Soße, Fleisch, Salat, Brot | Soße oder Fleisch |
| Vegetarisch | Ohne Fleisch | Falafel, Halloumi, veganer Döner, Soße, Salat, Brot | Falafel, Halloumi oder veganer Döner |
| Vegan | Vegan | Falafel, veganer Döner, vegane Soße, Hummus, Salat, Brot | eines davon außer Brot |

### Profil

Ein Profil für alle, ein Tipp auf einen Namen (Feed, Laden, Freundesliste, Suche) öffnet es. Es zeigt Name, Stufe, „Seit [Monat Jahr]“ ab dem ersten Check-in oder der ersten Bewertung, die Zahl der bewerteten Läden und drei Tabs:
- **Top 5:** die persönliche Bestenliste, die bestbewerteten Läden der Person, gerechnet mit der Ernährung dessen, der schaut
- **Bewertungen:** alle Bewertungen der Person
- **Check-ins:** nur für Freunde und einen selbst, für alle anderen gesperrt

Am fremden Profil stehen „Als Freund hinzufügen“ und ⋮ zum Blockieren. Das eigene Profil zeigt zusätzlich die Reaktionen der Freunde unter Bewertungen und Check-ins, wie viele Läden bis zur nächsten Stufe fehlen, die Zahl der Check-ins und Freunde, noch nicht übertragene Einträge (markiert) und das Menü mit Freunden, „Meine Läden“ (alle besuchten oder bewerteten Läden, sortierbar nach Bewertung, Besuchen oder zuletzt besucht) und Wrapped.

Die Stufe steht neben dem Namen und richtet sich nach bewerteten Läden (`Tier` in `packages/doener_models`):

| Stufe | Ab bewerteten Läden |
|---|---|
| Dönerneuling | 0 |
| Dönerfreund | 3 |
| Dönerfan | 10 |
| Dönerprofi | 25 |
| Dönermeister | 50 |
| Dönerlegende | 100 |

### Döner Wrapped

Nur im Dezember, sonst ausgegraut. Jahresrückblick auf 5 Seiten auf dunklem Grund: Besuche im Jahr, Lieblingsessen, Stammladen, entdeckte Läden, Zusammenfassung mit aktivstem Monat.

### Start

Der erste Tab, für den Umkreis von 10 km um den Standort (ohne Standort: Freiburg):

- Ganz oben die Freunde, die gerade essen
- Die neueste Neuigkeit zur App als Karte, bis man sie ausblendet (siehe „Neuigkeiten“)
- Startaufgaben, bis sie erledigt sind: „Bewerte deinen Stammladen“ (führt zur Karte) und „Hol deine Freunde per QR-Code“
- „Neu in [Stadt]“: Läden, die in den letzten 30 Tagen aufgemacht haben, und Eröffnungen, die Google angekündigt hat („Bald: … Laut Google am 15. Oktober“)
- „Top 3 hier“: nach gewichtetem Schnitt der Note zur Ernährung, wie im Ranking. Gibt es zu wenige bewertete Läden, füllen die nächstgelegenen als „noch unbewertet“ auf
- „Gerade im Trend“: meiste Check-ins und Bewertungen der letzten 7 Tage, Check-ins zählen anonym
- Feed: Check-ins und Bewertungen der Freunde (mit Linie in der Akzentfarbe) und die Bewertungen aller anderen im Umkreis, mit Namen. Check-ins sehen nur Freunde. Der Filter „Nur Freunde“ blendet die anderen aus, die eigene Aktivität steht im Profil
- Reaktionen: Unter Check-ins und Bewertungen von Freunden reagiert man mit 🤤, 🥙 oder 🙋, eine Reaktion pro Person und Post, ein zweiter Tipp nimmt sie zurück. Angezeigt wird die Zahl je Emoji, darunter, wer reagiert hat: mit Namen nur eigene Freunde („Tom 🤤, Anna 🥙 und 2 weitere“), so verrät der Post nicht, wer mit wem befreundet ist. Reagieren dürfen nur Freunde der Person, die Ladenseite zeigt keine Reaktionen. Wer gepostet hat, sieht sie im eigenen Profil, ohne Push

### Ranking

Ranking der Stadt laut Adresse; die Stadt ist die des nächsten bekannten Ladens im Umkreis von 20 km. Gerankt wird der Laden, umschaltbar per Chips: zuerst die Note zur Ernährung, dann einzelne Punkte (bei „Alles“ Soße, Fleisch, Salat, Brot, Falafel, Halloumi, Vegan, Pizza, Pide, Lahmacun, Seele, Ayran).

- Sortiert wird nach gewichtetem Schnitt: Jeder Laden startet mit drei Bewertungen in Höhe des Stadtschnitts (`weightedRating` in `packages/doener_models`). So schlägt eine einzelne 5 nicht viele 4,5er
- Angezeigt werden echter Schnitt und Anzahl, dazu die Freunde, die den Laden bewertet haben, mit ihrer Note, und der Median der Preisangaben
- Preisfilter „bis 6/7/8 €“: nur Läden, deren Median-Preis darunter liegt, in der Reihenfolge des ganzen Rankings. Läden ohne Preisangabe fallen dann heraus
- Zutatenfilter (z. B. „Mit Rote Zwiebel“): nur Läden, bei denen mindestens die Hälfte der Experten die Zutat angekreuzt hat, wie beim Laden unter „Mit allem heißt hier …“. Läden ohne Expertenangaben fallen dann heraus

### Andere Stadt ansehen

Wer in seiner Gegend noch niemanden hat, schaut woanders rein: Der Knopf neben „Top 3“ auf Start und die Weltkugel im Ranking öffnen „Döner-Tourismus“ mit allen Städten, in denen Läden bewertet sind (`/cities`, die meisten zuerst). Start (Top 3, Trends, neue Läden, Bewertungen der Gegend) und Ranking zeigen dann diese Stadt, ein Hinweis auf Start führt zurück. Die Wahl gilt bis zum Neustart der App, Check-in und Erinnerungen bleiben am echten Standort.

### Bestenliste und Siegel

Am 1. Januar friert der Server für jede Stadt die Bestenliste des Vorjahres ein (Zeitplan `best_of`, Tabelle `best_of`, erstes Jahr 2026), gesamt und vegan.

- Gezählt werden Bewertungen, die im Kalenderjahr (Europe/Berlin) abgegeben oder zuletzt geändert wurden. Ein Laden braucht mindestens 10 davon (vegan: 10 mit veganer Note), eine Stadt mindestens 5 solche Läden. Sortiert wird wie im Ranking, der Stadtschnitt kommt aus allen Bewertungen des Jahres. Die Regeln stehen als Konstanten in `packages/doener_models` (`bestOf…`)
- Platz 1–3 bekommen ein Siegel: „Platz 1 in Freiburg 2026“. Kein „Testsieger“, denn es gab keinen Test
- Öffentliche Seite `/bestenliste/<stadt>/<jahr>` (`?lang=en` englisch) mit Top 3 je Kategorie, den weiteren Plätzen und der Methodik. Das Zitat ist die längste Bewertung mit Text aus dem Jahr, ohne Namen, und wird beim Aufruf gelesen: Eine gelöschte Bewertung nimmt ihr Zitat mit
- Siegel zum Drucken unter `/siegel/<placeId>`, 15 × 5 cm, mit QR-Code auf `/b/<placeId>`. Druck und Versand an die Läden sind noch offen
- In der App: Zeile über dem Ladennamen, Link zur Liste und „Siegel drucken“ in der Laden-Ansicht, Banner mit den Top 3 über dem Ranking. Gezeigt wird immer das neueste Jahr. Die Karte bleibt unverändert

### Freunde

- Persönlicher Einladungslink samt QR-Code (Profil, Freunde-Liste, letzter Onboarding-Schritt): Wer ihn öffnet und sich anmeldet, ist sofort befreundet, eine offene Anfrage gilt damit als angenommen. Der Link lässt sich zurücksetzen.
- Ist die iOS-App installiert, öffnet der Link sie direkt (Universal Links, Domains in `app/ios/Runner/Runner.entitlements`). Ohne App führt er auf eine Einladungsseite (`/i/<code>`) mit Chat-Vorschau. Wer im Browser angemeldet ist, geht weiter in die Web-App und ist befreundet, alle anderen bewerben sich als Tester (siehe Registrierung).
- Freunde per Namenssuche finden (ab 2 Zeichen); wer eine offene Anfrage zurückschickt, nimmt sie damit an

### Push

Über Firebase Cloud Messaging für iOS, Android und Web (Firebase im GCP-Projekt `doener-app-510118`). Zwei Arten, jede mit Schalter unter Einstellungen → Benachrichtigungen:
- **Freunde checken ein:** „Lena isst gerade 🌯“, darunter „bei X (Nr. 2 in Freiburg)“ mit dem Platz im Döner-Ranking der Stadt. Nur für Check-ins, die gerade passieren, und pro Person höchstens alle 3 Stunden. Einzelne Freunde lassen sich in der Freundesliste mit der Glocke stummschalten
- **Neue Läden in deiner Stadt:** sobald ein angekündigter Laden aufmacht, einmal an alle in der Stadt. Die Stadt nimmt der Server vom nächsten Laden zur Position, die das Gerät mit seinem Token schickt

Ein Tipp auf den Push öffnet den Laden. Handys fragen beim Start nach der Erlaubnis, Browser erst beim Einschalten eines Schalters, weil sie das nur nach einem Tipp erlauben. Beim Abmelden meldet die App das Gerät ab, Tokens, die FCM nicht mehr kennt, löscht der Server.

Faire Benachrichtigungen nach starter (AGENTS.md, „Benachrichtigungen“), alles pro Konto auf dem Server und damit auf allen Geräten gleich:
- **Pausieren** unter Einstellungen → Benachrichtigungen: 1 Stunde, bis morgen 8 Uhr, 1 Woche oder bis zum Fortsetzen (`push_paused_until`, „bis zum Fortsetzen“ ist das Jahr 9999). Neuigkeiten per Mail sind nicht betroffen
- **Ruhezeiten:** ein Zeitfenster mit Wochentagen, voreingestellt jeden Tag 22–8 Uhr. Ein Fenster über Mitternacht gehört zu dem Tag, an dem es beginnt (SQL-Funktion `in_quiet_hours`). Es gilt die Zeitzone, die das Gerät mit seinem Token meldet, sonst `Europe/Berlin`
- In Ruhezeit oder Pause fallen Check-ins von Freunden weg, sie sind bis dahin vorbei. Neue Läden warten (`push_events.pending`) und gehen danach raus (`pushPending`, jede Minute), außer man hat sie schon in der Glocke gesehen oder es ist mehr als ein Tag vergangen
- **Zusammenfassen:** Checken mehrere Freunde innerhalb von 30 Minuten ein, ändert der Server das Ereignis („Anna und Carl essen gerade 🥙“, ab drei „Anna und 2 weitere …“) und schickt das Signal mit derselben ID noch einmal, das Gerät ersetzt die Meldung
- **„Weniger davon“** hängt an jeder Meldung (Android-Aktion, iOS-Kategorie `push`, im Web eine Aktion des Service Workers, die `/app?less=<art>:<id>` öffnet) und an Check-ins und neuen Läden in der Glocke: den Freund stummschalten oder die Art abschalten

**Die Glocke** oben auf Start (`GET /me/inbox`) zeigt die letzten 7 Tage: Check-ins und Bewertungen von Freunden, Reaktionen auf eigene Posts, offene Freundschaftsanfragen, neue Läden in der eigenen Stadt und Neuigkeiten. Sie entsteht aus diesen Daten selbst, nicht aus den Pushes, und funktioniert so auch ohne Push. Die Zahl an der Glocke zählt, was seit dem letzten Öffnen dazukam; das Öffnen (`POST /me/inbox/seen`) gilt auf allen Geräten.

Ein Push ist nur ein Signal: Er trägt die Art (`friend_check_in`, `new_place`) und eine Ereignis-ID, keine Namen und Läden. Den Text legt der Server 7 Tage lang in `push_events` ab, das Gerät holt ihn über `GET /push-events/:id` mit seinem Geräteschlüssel (`Authorization: Push …`, beim Token gemeldet, auf dem iPhone nach dem ersten Entsperren lesbar) und zeigt die Meldung selbst an: Android und iOS mit `flutter_local_notifications`, das Web im Service Worker `firebase-messaging-sw.js`. Scheitert der Abruf, steht nur die Art da („Ein Freund ist gerade beim Döner …“). Ausgelieferte Versionen ohne Schlüssel bekommen immer diesen neutralen Text als normale Benachrichtigung. Zustellung ohne Garantie: Android weckt die App in der Regel für jedes Signal, aber nicht nach einem erzwungenen Stopp und nicht zuverlässig bei aggressivem Energiesparen. iOS stellt Hintergrund-Pushes nur zu, wenn es will, gedrosselt und gar nicht mehr, nachdem man die App weggewischt hat. Browser nur, solange sie laufen; ist der Tab gerade offen und sichtbar, zeigt das Web wie bisher keine Meldung.

### Neuigkeiten

Was neu ist in der App, steht als Karte auf Start und geht auf Wunsch per Mail raus.

- Opt-in: „Neuigkeiten per Mail“ ist aus, bis man es auf der Karte („Auch per Mail bekommen“) oder unter Einstellungen → Benachrichtigungen einschaltet. `users.updates_consent_at` hält den Zeitpunkt als Nachweis; die Adresse ist durch den Login schon bestätigt.
- Abmelden: Jede Mail hat einen Link auf `/abmelden?token=…` (Seite mit Knopf, damit Link-Scanner niemanden abmelden) und `List-Unsubscribe` mit One-Click auf `POST /api/v1/updates/unsubscribe?token=…`. Der Token steht pro Konto in `users.unsubscribe_token`.
- Schreiben: Admins (`ADMIN_EMAILS`) unter Profil → Neuigkeiten, mit Vorschau der Karte und „Testmail an mich“. Agenten schreiben Entwürfe als `updates/<datum>-<thema>.md` (`# Titel`, darunter Punkte `- …`); der Server legt jede Datei beim Start einmal als Entwurf an und überschreibt ihn nie, die Server-Tests prüfen alle Dateien.
- Veröffentlichen: nur ein Admin, nie ein Agent, auch nicht per API oder Datenbank, denn die Mail geht in Robins Namen an andere. Angekreuzt wird, ob die Karte erscheint und ob die Mail rausgeht. Danach ist der Text fest.
- Versand: Jede Minute schickt jede Instanz bis zu 5 fällige Mails aus `update_deliveries`, drei Versuche je Mail. Wer inzwischen abbestellt hat, wird übersprungen.

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

### Für Agenten

Fremde Agenten lesen die öffentlichen Inhalte ohne HTML, nach [llms.txt](https://llmstxt.org). Quelle ist `publicPages` in `server/lib/src/agents.dart`: die Landingpage, jede Bestenliste und die Datenschutzerklärung.

- `/llms.txt`: Einstieg mit Name, Beschreibung und allen öffentlichen Seiten als Links auf ihr Markdown.
- `/llms-full.txt`: alle Seiten in einer Datei.
- `<seite>.md`: jede Seite als Markdown, die Landingpage als `/index.md`. Wer mit `Accept: text/markdown` nach einer dieser Seiten fragt (auch `/en`), bekommt unter derselben URL gleich das Markdown, alle anderen das HTML.
- Sprache: `?lang=de|en`, sonst `Accept-Language`, sonst Deutsch. Links behalten ein `?lang=`. Die Datenschutzerklärung gibt es nur auf Deutsch.
- Nur öffentliche Inhalte: Bestenlisten mit Plätzen, Schnitt und Anzahl, aber ohne die Zitate aus Bewertungen. Keine Profile, keine Einladungen.
- Ausprobieren: `curl localhost:8080/llms.txt` bei laufendem Server.

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
cli/                          Befehlszeile `doener` gegen dieselbe API, siehe „CLI“
packages/doener_models/       Geteilte DTOs, Validierung, Bewertungspunkte und Ernährung (`menu.dart`), Ranking-Regel, Stufen und Essenstypen
```

**Prinzipien:**
- Offline-First: Die App zeigt alles aus dem lokalen Store. Eigene Besuche und Bewertungen warten in einer Queue, bis der Server sie bestätigt.
- Bei einem Netzwerkfehler versucht die App es später erneut, auch eine abgelaufene Sitzung verwirft keine Einträge. Nur was der Server endgültig ablehnt (z. B. ungültige Daten), wird verworfen.
- Der Server ist die Quelle der Wahrheit für den Account. Ein neues Gerät oder die Web-App holt sich Besuche und Bewertungen über `/me/*`.
- Favoriten bleiben lokal auf dem Gerät.

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
| GET | `/ranking?lat&lon&by[&city][&maxPrice][&ingredient]` | Ranking der Stadt nach `overall`, `vegetarian`, `vegan` oder einem Punkt (`sauce`, `falafel`, `ayran` …), mit Freunden, Median-Preis und den Top 3 der neuesten Bestenliste; `city` statt der Stadt am Standort, `maxPrice` in Cent, `ingredient` eine Zutat wie `roteZwiebel` |
| GET | `/cities` | Städte mit bewerteten Läden samt Mittelpunkt, die meisten zuerst |
| GET | `/places/search?q[&lat&lon]` | Alle bekannten Läden nach Namen, mit Position die nächsten zuerst |
| GET | `/places/:placeId` | Laden (Google Place ID); fehlt er im Cache oder fehlen Öffnungszeiten, lädt der Server sie für Angemeldete bei Google nach |
| GET | `/places/:placeId/reviews` | Bewertungen des Ladens, angemeldet ohne die von Blockierten |
| GET | `/places/:placeId/summary` | Durchschnitt je Punkt, Ayran, was „mit allem“ heißt und die Siegel aus der neuesten Bestenliste |
| PUT | `/places/:placeId/review` | Eigene Bewertung speichern, optional mit Foto (`photoBase64`) oder ohne das bisherige (`removePhoto`) |
| GET | `/photos/:id` | Foto einer Bewertung (ohne Login) |
| POST | `/places/:placeId/visits` | Check-in (idempotent über Client-ID) |
| GET | `/me/visits`, `/me/reviews`, `/me/places` | Eigene Daten, Check-ins und Bewertungen mit den Reaktionen der Freunde |
| GET | `/users/:id/profile` | Öffentliches Profil: Stufe und Bewertungen, für Freunde auch die Check-ins |
| DELETE | `/me/live-status` | Live-Status beenden |
| GET | `/feed?cursor[&lat&lon]` | Check-ins und Bewertungen der Freunde, mit `lat`/`lon` auch alle Bewertungen im Umkreis (Keyset-Pagination) |
| GET | `/feed/live` | Live-Status der Freunde |
| PUT/DELETE | `/visits/:id/reaction`, `/reviews/:id/reaction` | Auf den Post eines Freundes reagieren (`emoji`) oder die Reaktion zurücknehmen |
| GET | `/users/search?q` | Nutzer suchen |
| GET | `/friends` | Freundschaften |
| POST | `/friends/requests` | Anfrage senden |
| POST | `/friends/:id/accept` | Anfrage annehmen |
| DELETE | `/friends/:id` | Freundschaft entfernen |
| GET | `/me/invite` | Eigener Einladungslink |
| POST | `/me/invite/reset` | Neuer Einladungslink, der alte verfällt |
| GET | `/invites/:code` | Wer einlädt (ohne Login) |
| POST | `/invites/:code/accept` | Einladung annehmen → sofort befreundet |
| PUT | `/me/push-token` | FCM-Token des Geräts mit Geräteschlüssel, optional mit Position für die Stadt und Zeitzone für die Ruhezeiten |
| GET | `/push-events/:id` | Text eines Pushes, mit `Authorization: Push <Geräteschlüssel>` statt Sitzung |
| GET | `/me/inbox` | Die Glocke: was in den letzten 7 Tagen passiert ist, mit `seenAt` |
| POST | `/me/inbox/seen` | Glocke geöffnet, auf allen Geräten |
| GET | `/updates/current` | Neueste Neuigkeit für die Karte, 204 ohne |
| POST | `/updates/:id/dismiss` | Karte ausblenden |
| POST | `/updates/unsubscribe?token=` | One-Click-Abmeldung aus der Mail, ohne Login |
| GET, POST | `/admin/updates` | Neuigkeiten mit Versandzahlen, neuer Entwurf (Admins) |
| PUT | `/admin/updates/:id` | Entwurf ändern |
| POST | `/admin/updates/:id/test`, `/admin/updates/:id/publish` | Testmail an sich, veröffentlichen |
| DELETE | `/me/push-tokens/:token` | Gerät abmelden |
| PUT, DELETE | `/me/mutes/:userId` | Freund stummschalten, wieder laut |
| POST | `/feedback` | Feedback mit optionalem Screenshot |
| POST | `/shop-reports` | Fehlenden Laden melden |
| POST | `/reviews/:id/report` | Bewertung melden |
| DELETE | `/reviews/:id` | Bewertung entfernen (Admins) |
| GET | `/me/blocks` | Blockierte Nutzer |
| PUT, DELETE | `/me/blocks/:userId` | Blockieren, freigeben |
| POST | `/tester-requests` | Testanfrage von der Landingpage, ohne Login, optional mit `inviteCode` |
| GET | `/tester-requests` | Offene Testanfragen (Admins) |
| POST | `/tester-requests/:id/invite` | Anfrage freischalten: Konto, Login-Mail, bei iOS TestFlight (Admins) |
| DELETE | `/tester-requests/:id` | Anfrage ablehnen (Admins) |

Außerhalb von `/api/v1` liefert der Server unter `/i/:code` die Einladungsseite aus, unter `/b/:placeId` die Bewertungsseite eines Ladens, unter `/aushang/:placeId` dessen Aushang mit QR-Code, unter `/siegel/:placeId` seine Siegel zum Drucken, unter `/bestenliste/:stadt/:jahr` die Bestenliste und unter `/.well-known/apple-app-site-association` die Freigabe, mit der iOS Einladungs- und Bewertungslinks in der App öffnet.

---

## Entwicklung

Voraussetzung: [Flutter-SDK](https://docs.flutter.dev/get-started/install) (bringt Dart mit) und Docker. iOS-Builds brauchen macOS – das übernimmt die CI, entwickelt werden kann komplett unter Linux.

### Alles in einem

```bash
docker compose up --build        # App + API auf http://localhost:8080, Postgres auf 127.0.0.1:5434
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
cd cli && TEST_DB_PORT=5434 TEST_DB_USER=doener TEST_DB_PASSWORD=doener dart test      # legt DB doener_cli_test neu an
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
| `UPDATES_DIR` | `../updates` | Entwürfe für Neuigkeiten, im Image `/app/updates` |
| `CORS_ORIGIN` | – | Nur für lokale Web-Entwicklung |
| `APP_DOWNLOAD_URL` | – | App-Link in der Mail einer Admin-Einladung |
| `FCM_SERVICE_ACCOUNT` | – | JSON-Key (base64) des Dienstkontos, das über FCM sendet; ohne stehen Pushes nur im Log |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | – | App-Store-Connect-Key (`.p8` als Base64) für TestFlight-Einladungen beim Freischalten; ohne bleibt das Handarbeit |
| `TESTFLIGHT_GROUP` | `Erste Tester` | Externe TestFlight-Gruppe |
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

## CLI

`cli/` ist die Befehlszeile der App, damit Agenten, Skripte und Tests sie über Befehle für die Sache selbst bedienen statt über die UI. Sie spricht nur mit der HTTP-API unter `/api/v1` wie die App, nie mit der Datenbank. So gelten dieselben Rechte, Rate-Limits und die geschlossene Registrierung samt Robins Freischaltung. Die DTOs kommen aus `packages/doener_models`, die Argumente liest `package:args`.

- Bauen: `cd cli && mkdir -p build && dart compile exe bin/doener.dart -o build/doener`, eine einzelne Datei von gut 7 MB für die Plattform, auf der sie gebaut wird. Eingebaut ist die Live-API `https://doener-api.pleasance.org`, `--define=CLI_URL=<url>` beim Bauen nennt eine andere. `--url` wählt sie pro Aufruf, etwa `http://localhost:8080` gegen den lokalen Server, danach gilt die Adresse des letzten Logins. Ohne Bauen: `dart run bin/doener.dart <befehl>`.
- Anmelden: `doener login` fragt nach der Adresse und dem Code aus der Mail, wie die App. `doener login --link <link>` löst einen Login-Link aus der Mail ein, `--link -` liest ihn von stdin. Danach liegt der Token dieses Geräts mit `0600` in `$XDG_CONFIG_HOME/doener/session.json` (sonst `~/.config`, unter macOS `~/Library/Application Support`, unter Windows `%APPDATA%`), zusammen mit der Adresse, an andere Adressen geht er nie. Er ist eine gewöhnliche Session als Bearer: gehasht in `sessions`, 365 Tage, verlängert sich bei Nutzung, jedes Gerät hat seine eigene. `whoami` zeigt das Konto, `logout` widerruft den Token auf dem Server und löscht die Datei, ein neuer Login widerruft den alten.
- Befehle: `doener --help`. `nearby --lat <breite> --lon <länge>` zeigt die besten Läden im Umkreis wie auf Start (`/places/top`, mit `--radius`, `--by overall|vegetarian|vegan`, `--limit`). Angemeldet: `search --name <text>` sucht Läden nach Namen (`/places/search`, mit `--lat`/`--lon` die nächsten zuerst), `ranking` die Bestenliste der Stadt (`/ranking`, mit `--city`, `--by`, `--max-price`, `--ingredient`), `feed` (Seiten über `--cursor`), `inbox` wie die Glocke (`--seen` markiert alles als gesehen), `friends`, `users --search <name>` und `befriend --user <id>`, das eine Anfrage sendet oder eine erhaltene annimmt, `unfriend --user <id>`, das eine Freundschaft beendet oder eine Anfrage zurückzieht oder ablehnt, `mute`/`unmute --user <id>` für Pushes bei Check-ins, die eigenen `reviews` und `visits`. `review --place <placeId> --rate sauce=4,5 …` bewertet und ändert dabei nur die genannten Punkte, Preis und Text, alles andere der bisherigen Bewertung bleibt. `checkin --place <placeId> [--food <essen>]` checkt ein. Die `placeId` steht in `nearby --json` und `ranking --json`, einen unbekannten Laden lädt der Server bei Google nach.
- Ausgabe: Text für Menschen, mit `--json` genau ein JSON-Wert auf stdout, auch Fehler als `{"error": "…"}` und die Hilfe als Liste der Befehle. Exit-Codes: 0 erledigt, 1 Fehler (auch Absagen der API wie die geschlossene Registrierung), 2 falscher Aufruf, 3 nicht angemeldet.
- Eigene Befehle: Datei in `cli/lib/src/commands` nach dem Beispiel `nearby.dart` und in `commands` in `cli/lib/cli.dart` eintragen. Ein Befehl nennt Hilfezeilen, Optionen und `run`. Das ruft über `ctx.api` die API auf, liest die Antwort mit dem `fromJson` des Modells (`parse`) und gibt `(data:, text:)` zurück, `data` für `--json`. `requireLogin(ctx)` verlangt den Login, `currentUser(ctx)` holt dazu das Konto, Fehler enden als `Failure` mit einem Code aus `Exit`. Die Tests in `cli/test/cli_test.dart` rufen die CLI im Prozess gegen den echten Server auf einem freien Port auf, mit eigener Testdatenbank.
- Agenten: nur mit dem Testkonto admin@pleasance.org, nie mit Kundenkonten. Den Token holen sie über den Login-Link aus dem Kontor, per Pipe, so steht der Link nicht in ihrem Kontext: `login-link doener | cli/build/doener login --link -`. Danach bleibt die CLI auf diesem Rechner angemeldet.
- Verteilen: Die CI baut die Datei bei jedem Lauf zur Probe, veröffentlicht sie aber nicht. Release-Artefakte erst, wenn die CLI an Menschen außerhalb des Repos geht.

## Deployment

| Workflow | Auslöser | Macht |
|---|---|---|
| `ci.yml` | PRs, Push auf `main` | Analyse + Tests für Models, Server (mit Postgres), CLI und App, dazu ein Probe-Build der CLI |
| `deploy.yml` | Push auf `main` (`server/`, `app/`, `packages/`) | arm64-Image `ghcr.io/robinchoice/doener-api:<sha>` bauen, auf Coolify deployen |
| `mobile.yml` | Tags `v*`, manuell | iOS → TestFlight, Android → App Bundle als Artefakt und in den internen Play-Test |
| `secrets.yml` | Jeder Push auf jedem Branch, PRs aus Forks | Secret-Scan mit gitleaks, siehe unten |

Das Image enthält Server und Web-App: Die API liegt unter `/api/v1`, die Landingpage unter `/` und `/en`, alles andere ist die Web-App (`/app`).

**Secrets:**
- Coolify: `COOLIFY_UUID`, `COOLIFY_TOKEN`
- Google Maps: `GOOGLE_MAPS_IOS_KEY`, `GOOGLE_MAPS_ANDROID_KEY`, `GOOGLE_MAPS_WEB_KEY`
- iOS: `ASC_KEY_P8` (Base64), `ASC_KEY_ID`, `ASC_ISSUER_ID`, dazu `IOS_DEV_CERTIFICATE` (Base64-PKCS12 eines festen „Apple Development“-Zertifikats, läuft am 04.10.2027 ab) und `IOS_DEV_CERTIFICATE_PASSWORD`. Ohne festes Zertifikat legt Xcode pro Lauf ein neues an, bis die Zertifikatsgrenze des Teams erreicht ist.
- Android: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` – ohne sie wird mit Debug-Keys signiert
- Play: `PLAY_SERVICE_ACCOUNT_JSON` (Dienstkonto mit Release-Rechten für die App in der Play Console) – ohne es bleibt es beim Artefakt. Die API nimmt erst Uploads an, wenn das erste App Bundle von Hand hochgeladen wurde

Die Build-Nummer steigt pro Lauf automatisch (TestFlight lehnt doppelte ab): Sie ist die Run-Nummer von `mobile.yml` plus 10.

**Stacktraces der App:** Release-Builds sind mit `--obfuscate` gebaut, Stacktraces aus der App (auch in GlitchTip) zeigen nur verschleierte Namen. Die Symbole liegen 90 Tage als Artefakt `symbols-android` (Unterordner `aab/` und `apk/`, je nachdem, was installiert ist) bzw. `symbols-ios` am Lauf. Zur Build-Nummer gehört die Run-Nummer minus 10, `gh run list -w mobile.yml --json number,databaseId` liefert die Run-ID dazu. Lesbar machen:

```bash
gh run download <run-id> -n symbols-android -D /tmp/symbols
flutter symbolize -i trace.txt -d /tmp/symbols/apk/app.android-arm64.symbols   # iOS: app.ios-arm64.symbols
```

`trace.txt` ist der rohe Stacktrace mit `build_id` und `abs …/virt …`-Zeilen (z. B. aus `adb logcat`). Builds, die älter als 90 Tage sind, lassen sich nicht mehr symbolisieren. Keine Secrets im Client: Die Verschleierung schützt nichts, alles im App-Bundle lässt sich auslesen.

### Secret-Scan

Das Repo ist öffentlich, Code, Historie und CI-Logs. `.github/workflows/secrets.yml` läuft bei jedem Push auf jedem Branch und bei PRs aus Forks, ohne `paths-ignore`, und scannt mit gitleaks (Docker-Image, Version per Digest fest) die neuen Commits. Ein Fund macht den Lauf rot, der Wert steht dank `--redact` nicht im Log.

- Regeln: die Standardregeln von gitleaks, dazu `.gitleaks.toml`. Die nimmt nur `generic-api-key` in `pubspec.lock` aus, dort können Paket-Hashes anschlagen. Echte Token-Formate fallen dort weiter auf.
- Fehlalarm: den `Fingerprint` aus dem Log als Zeile in `.gitleaksignore` eintragen.
- Echter Fund: Der Scan läuft erst nach dem Push, das Secret ist also schon öffentlich. Sofort rotieren, Entfernen aus dem Code oder der Historie reicht nicht.
- Ganze Historie lokal: `docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:v8.30.1 git /repo --redact`

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
- **Nach dem Check-in:** Freunde bekommen einen Push mit dem Platz im Ranking („Tom isst gerade 🥙 bei X (Nr. 2 in Freiburg)“) und reagieren im Feed mit 🤤, 🥙 oder 🙋, auch auf Bewertungen. Nach etwa 30 Minuten fragt die App „Wie war's bei X?“. Wer den Laden schon bewertet hat, bekommt „Bleibt's bei 4,5?“.
- **Bewertung:** optional mit Foto. Bewerten darf jeder, wer eingecheckt hat, bekommt das Häkchen „vor Ort“. Den Spruch unter dem Laden liefert ab Phase 2 die Bewertung mit den meisten Upvotes.
- **Push nur für Freunde und neue Läden:** Check-ins von Freunden (pro Person höchstens alle 3 Stunden) und „Neuer Döner hat in Freiburg aufgemacht“ an alle in der Stadt, sobald ein angekündigter Laden offen ist. Dazu als Ausnahme die eigene Bewertungserinnerung. Antworten, neue Fragen, Upvotes und Ranking-Änderungen zeigt nur die App. Jede Art ist abschaltbar, Freunde einzeln stummschaltbar, dazu Pause und Ruhezeiten. Was man verpasst hat, steht in der Glocke auf Start.
- **Belohnung:** Ab Phase 2 zählen die Upvotes zur Stufe.
- **Texte:** Einladung „Welcher Döner ist der beste in [Stadt]? Die Döner-App weiß es, und du siehst, wo ich gerade esse: [Link]“, App-Store-Untertitel „Der beste Döner deiner Stadt“.

### Phase 1 – Bester Döner der Stadt

- Universal Links auch für den Magic-Link (bis dahin: Code eintippen)

### Phase 2 – Community

- Fragen an den Umkreis, Antworten mit verlinktem Laden
- Kommentare unter Freunden an Check-ins und Bewertungen im Feed, wie bei Instagram. Sie bleiben am Post und erscheinen nicht auf der Ladenseite, damit sie Laden und Bewertungen nicht überfluten (Tester-Feedback vom 23.10.2026)
- Up- und Downvotes, ab −5 ausgeblendet, Upvotes neben dem Namen
- Kenner des Monats 👑 (meiste Upvotes in der Stadt)
- Favoriten werden zur Merkliste „Will ich probieren“

### Phase 3 – Läden

Langfristige Richtung (Robin, 28.10.2026), gebaut wird erst nach Phase 2. Vorbild für den Ladenbereich ist doener.app („Für Ladenbesitzer“, Teardown im Savor-Dokument „Teardowns: Döner“).

- **Laden beanspruchen:** Antrag mit Gewerbenachweis, Robin prüft von Hand. Danach pflegt der Inhaber Karte und Preise, Öffnungszeiten und Angebote, antwortet auf Bewertungen und sieht Statistiken (Aufrufe, Check-ins, Bewertungen). Nachweise und Inhaberdaten erst erheben, wenn das gebaut wird.
- **Gutscheine:** Jeder Laden entwirft eigene Gutscheine wie bei McDonald's oder Burger King und löst sie selbst ein, z. B. per QR-Code an der Kasse.
- **Stempelkarte:** Der Laden legt seine Regel fest (z. B. jeder 10. Döner gratis). Den Stempel gibt der Laden an der Kasse per QR-Code, nicht der Check-in, denn der lässt sich ohne Kauf auslösen.
- **Bezahlte Plätze:** klar als „Anzeige“ markiert und neben dem Ranking, z. B. oben in Suche oder Karte, ein hervorgehobener Pin oder ein Angebot auf Start. Gezielt wird nur nach Ort, nicht nach Nutzerdaten. Dazu eventuell ein Abo für Inhaber.
- **Zahlungen annehmen:** Der Laden kassiert per Smartphone (Tap to Pay) über die Döner-App statt über SumUp, wir verdienen an jeder Zahlung. Lightning ist dabei.

Grenzen und Offenes:
- Ranking, Bestenliste und Siegel sind nicht käuflich. Bezahlte Platzierung im Ranking müsste nach § 5b UWG offengelegt werden und würde den Kern der App entwerten.
- Bezahlte Plätze lohnen sich erst mit genug Nutzern pro Stadt, also nach dem Öffnen der Registrierung.
- Kartenzahlung geht nur über einen lizenzierten Partner (Acquirer bzw. Zahlungsdienst mit Tap-to-Pay-SDK), selbst brauchten wir eine BaFin-Erlaubnis nach ZAG. Gebühren und Marge gegen SumUp rechnen, bevor gebaut wird. Lightning geht ohne Partner und ist für Läden am günstigsten.

### Messen

Skript über die Datenbank, Ziele nach 4 Wochen:
- Anteil der Check-ins mit Bewertung danach
- Läden der Stadt mit mindestens 3 Bewertungen
- Ab Phase 2: Anteil der Fragen mit Antwort binnen 24 Stunden
- K-Faktor über Einladungslinks

### Voraussetzungen und Offenes

- APNs-Schlüssel im Apple-Developer-Konto, hochgeladen in Firebase (sonst kommen auf iPhones keine Pushes an), und ab 1.0 eine eigene Domain unabhängig von pleasance.org für Landingpage, Web-App und Links (dann auch in `Runner.entitlements` und im Android-Manifest eintragen)
- Android-App-Links: Der Intent-Filter steht, es fehlt `/.well-known/assetlinks.json` mit dem SHA-256 des Release-Schlüssels. Bis dahin öffnen Einladungs- und Bewertungslinks auf Android den Browser, weil die CI ohne Keystore-Secrets mit wechselnden Debug-Keys signiert.
- Später: Bezirke für Großstädte. Falls Fakes auftauchen, zählen nur noch Bewertungen mit Häkchen voll.
