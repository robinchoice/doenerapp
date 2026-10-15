# Döner-App

## Zweck & Links

- Döner-Community für iOS, Android und Web aus einer Flutter-Codebase, Server in Dart. Web und API laufen unter https://doener-api.pleasance.org (Landingpage unter `/` und `/en`, API unter `/api/v1`, Web-App unter `/app`).
- Coolify auf VPS 1, Projekt `pleasance-doener`, Datenbank `doener-db`.
- Fachliche Regeln und der geplante Umbau: README.md.

## Checks

```sh
(cd packages/doener_models && dart pub get && dart analyze && dart test) &&
(cd server && dart pub get && dart analyze && dart test) &&
(cd app && flutter pub get && flutter analyze && flutter test)
```

## Deploy

- Ein Push auf `main`, der `server/`, `packages/`, `app/` oder das `Dockerfile` ändert, baut per `deploy.yml` das Image `ghcr.io/robinchoice/doener-api` (Web-Build und Server) und deployt es über die Coolify-API.
- Tags `v*` (und manuelle Läufe) bauen per `mobile.yml` die Android-App für den internen Play-Test und die iOS-App für TestFlight. Pushes auf `main` bauen keine App mehr, das sparte Actions-Minuten.
- TestFlight-Release (iOS) nur auf Anstoß, weil macOS-Minuten 10-fach zählen: Tag pushen (`git tag v1.2.3 && git push origin v1.2.3`) oder `gh workflow run Mobile`, beides baut iOS und Android. Nur Android: `gh workflow run Mobile -f platform=android`.
- Android liefert zwei Artefakte: `doener-android-aab` für Play und `doener-android-apk` (signiert mit dem Upload-Key) zum direkten Verschicken an Tester. Der Upload in den internen Play-Test läuft erst, wenn die Repo-Variable `PLAY_UPLOAD=true` gesetzt ist, also nach dem ersten Upload von Hand in der Play Console.
- Prüfen: `gh run watch`. Der Deploy-Job ist erst grün, wenn `https://doener-api.pleasance.org/api/v1/health` den Commit als `revision` meldet.
- Nach grünem Deploy fotografiert `tool/screenshots.mjs` die Landingpage (`/`, `/en`, Desktop und Handy) nach `docs/screenshots/` als WebP, der Bot committet geänderte Bilder mit `[skip ci]` auf `main`. Danach meldet der Job `notify` den Deploy per `repository_dispatch` `prototype-deployed` an `robinchoice/pleasance` (Secret `PLEASANCE_DISPATCH_TOKEN`). `/app` bleibt draußen, es braucht ein Login. Wegen des Bot-Commits vor dem nächsten Push holen. Lokal: `npm install --no-save --prefix tool playwright && node tool/screenshots.mjs [url]`.

## Fallen

- Die Adresse `doener-api.pleasance.org` bleibt für ausgelieferte Mobile-Clients erhalten. API-Änderungen müssen mit ihnen kompatibel bleiben.
- Der Maps-JavaScript-Key der Web-Version (`GOOGLE_MAPS_WEB_KEY`) ist per Referrer auf die Domains beschränkt. Neue Domain: Referrer im Google-Projekt ergänzen.

- Die Landingpage lädt Schrift und Wortmarke aus dem Flutter-Build (`/assets/assets/…`). Wer Assets in `app/pubspec.yaml` verschiebt, muss die Pfade in `server/lib/src/landing.dart` nachziehen.

## Abweichungen vom Standard

- Registrierung: Neben `SIGNUP_ALLOWLIST` und der Admin-Einladung (Profil → Tester einladen statt `/invite`) legt auch ein gültiger Freundes-Link (`inviteCode`, `/i/<code>`) ein neues Konto an, Robins Entscheidung vom 15.10.2026. Ein unbekannter Code öffnet nichts. Der Server prüft bei `/auth/login` (keine Mail an Fremde) und noch einmal bei `/auth/verify`. Ausgelieferte App-Builds vor dieser Änderung schicken den Code erst bei `/auth/verify`, über deren Freundes-Links kommen neue Adressen also erst ab dem nächsten Build herein.

- Zeitpläne laufen in der API statt in einem eigenen Worker: Jede Instanz fragt jede Minute `runSchedule` (Tabelle `schedules`), der atomare Claim lässt genau eine den Job ausführen. Ein neuer Job bekommt seine Zeile per Migration. Ein Worker als zweite Coolify-Anwendung bräuchte Kopien von DB-Zugang und Google-Key, die Agenten über die Coolify-API nicht lesen können.
