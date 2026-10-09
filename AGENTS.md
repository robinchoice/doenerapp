# Döner-App

## Zweck & Links

- Döner-Community für iOS, Android und Web aus einer Flutter-Codebase, Server in Dart. Web und API laufen unter https://doener-api.pleasance.org (API unter `/api/v1`, sonst der Web-Build).
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
- Änderungen an `app/` oder `packages/` bauen zusätzlich per `mobile.yml` die Android-App für den internen Play-Test.
- TestFlight-Release (iOS) nur auf Anstoß, weil macOS-Minuten 10-fach zählen: Tag pushen (`git tag v1.2.3 && git push origin v1.2.3`, baut nur iOS) oder `gh workflow run Mobile` (baut iOS und Android).
- Prüfen: `gh run watch`. Der Deploy-Job ist erst grün, wenn `https://doener-api.pleasance.org/api/v1/health` den Commit als `revision` meldet.

## Fallen

- Die Adresse `doener-api.pleasance.org` bleibt für ausgelieferte Mobile-Clients erhalten. API-Änderungen müssen mit ihnen kompatibel bleiben.
- Der Maps-JavaScript-Key der Web-Version (`GOOGLE_MAPS_WEB_KEY`) ist per Referrer auf die Domains beschränkt. Neue Domain: Referrer im Google-Projekt ergänzen.
