# Döner-App

## Zweck & Links

- Döner-Community für iOS, Android und Web aus einer Flutter-Codebase, Server in Dart. Web und API laufen unter https://doener-api.pleasance.org (Landingpage unter `/` und `/en`, API unter `/api/v1`, Web-App unter `/app`).
- Coolify auf VPS 1, Projekt `pleasance-doener`, Datenbank `doener-db`.
- Öffentlicher TestFlight-Link: https://testflight.apple.com/join/nJJ5wARs (externe Gruppe „Erste Tester“). Er steht als `APP_DOWNLOAD_URL` in Coolify und in der Mail einer Einladung ohne Android. `/i/<code>` und `/b/<placeId>` führen statt dorthin zur Bewerbung, weil ohne Konto nichts geht.
- Fachliche Regeln und der geplante Umbau: README.md.

## Checks

```sh
(cd packages/doener_models && dart pub get && dart analyze && dart test) &&
(cd server && dart pub get && dart analyze && dart test) &&
(cd app && flutter pub get && flutter analyze && flutter test)
```

## Deploy

- Ein Push auf `main`, der `server/`, `packages/`, `app/` oder das `Dockerfile` ändert, baut per `deploy.yml` das Image `ghcr.io/robinchoice/doener-api` (Web-Build und Server) und deployt es über die Coolify-API.
- `mobile.yml` baut die iOS-App für TestFlight und die Android-App für den internen Play-Test bei jedem Push auf `main`, der `app/`, `packages/` oder `mobile.yml` ändert. Das Repo ist öffentlich, die Actions-Minuten kosten nichts.
- Externe Tester (TestFlight-Gruppe „Erste Tester“, Public Link) bekommen nicht jeden Build: TestFlight mailt allen bei jedem Build, der der Gruppe zugeordnet wird. Zugeordnet und zur Beta-Prüfung eingereicht wird nur der Build eines Release-Tags `v*` (Job `testflight-release` in `mobile.yml`, `server/tool/testflight_release.dart`), und den setzt ein Agent nur auf Robins Anstoß. Alle anderen Builds landen nur in der internen Gruppe „Doener App Pioniere“.
- Außerdem bei Tags `v*` und von Hand: `gh workflow run Mobile` baut iOS und Android, `gh workflow run Mobile -f platform=android` nur Android.
- Android liefert zwei Artefakte: `doener-android-aab` für Play und `doener-android-apk` (signiert mit dem Upload-Key) zum direkten Verschicken an Tester. Der Upload in den internen Play-Test läuft erst, wenn die Repo-Variable `PLAY_UPLOAD=true` gesetzt ist, also nach dem ersten Upload von Hand in der Play Console.
- Prüfen: `gh run watch`. Der Deploy-Job ist erst grün, wenn `https://doener-api.pleasance.org/api/v1/health` den Commit als `revision` meldet.
- Nach grünem Deploy fotografiert `tool/screenshots.mjs` die Landingpage (`/`, `/en`, Desktop und Handy) nach `docs/screenshots/` als WebP, der Bot committet geänderte Bilder mit `[skip ci]` auf `main`. Danach meldet der Job `notify` den Deploy per `repository_dispatch` `prototype-deployed` an `robinchoice/pleasance` (Secret `PLEASANCE_DISPATCH_TOKEN`). `/app` bleibt draußen, es braucht ein Login. Wegen des Bot-Commits vor dem nächsten Push holen. Lokal: `npm install --no-save --prefix tool playwright && node tool/screenshots.mjs [url]`.

## Fallen

- Die Adresse `doener-api.pleasance.org` bleibt für ausgelieferte Mobile-Clients erhalten. API-Änderungen müssen mit ihnen kompatibel bleiben.
- Ausgelieferte Builds bis 1.0.x scheitern an unbekannten Namen von Bewertungspunkten. Neue `RatingItem`s kommen deshalb in `RatingItem.newItems`, das JSON trägt sie getrennt (`newRatings`, `newItems`).
- Der Maps-JavaScript-Key der Web-Version (`GOOGLE_MAPS_WEB_KEY`) ist per Referrer auf die Domains beschränkt. Neue Domain: Referrer im Google-Projekt ergänzen.

- Die Bestenliste eines Jahres friert der Zeitplan `best_of` am 1. Januar einmal ein (`best_of_years` merkt sich das Jahr). Wer die Regeln ändert und ein Jahr neu rechnen will, löscht dessen Zeilen in `best_of` und `best_of_years`, dann rechnet der nächste Lauf es neu.
- Die Landingpage lädt Schrift und Wortmarke aus dem Flutter-Build (`/assets/assets/…`). Wer Assets in `app/pubspec.yaml` verschiebt, muss die Pfade in `server/lib/src/landing.dart` nachziehen.
- Push läuft über Firebase. Die Firebase-Konfiguration steht fest in `app/lib/src/core/push.dart`, nur die API-Keys kommen per `--dart-define=FIREBASE_API_KEY` aus der CI. iOS nutzt dafür den Maps-Key `GOOGLE_MAPS_IOS_KEY`, der dazu auch Firebase Installations und FCM-Registrierung erlaubt. Den Web-Key setzt das `Dockerfile` zusätzlich in `firebase-messaging-sw.js` ein.

## Abweichungen vom Standard

- Registrierung: Neue Konten nur über `SIGNUP_ALLOWLIST` und Robins Freischaltung (Profil → Tester statt `/invite`, Bewerbungen von der Landingpage). Freundes-Links verbinden nur bestehende Konten, damit Tester niemanden weiter hereinholen (Robins Entscheidung vom 15.10.2026, nimmt die vom Vormittag zurück). Der Server prüft bei `/auth/login` (keine Mail an Fremde) und noch einmal bei `/auth/verify`.
- TestFlight: Das Freischalten unter Profil → Tester lädt iPhones über die App Store Connect API in „Erste Tester“ ein, der Key liegt dafür auch in Coolify (`ASC_*`).

- Zeitpläne laufen in der API statt in einem eigenen Worker: Jede Instanz fragt jede Minute `runSchedule` (Tabelle `schedules`), der atomare Claim lässt genau eine den Job ausführen. Ein neuer Job bekommt seine Zeile per Migration. Ein Worker als zweite Coolify-Anwendung bräuchte Kopien von DB-Zugang und Google-Key, die Agenten über die Coolify-API nicht lesen können.
