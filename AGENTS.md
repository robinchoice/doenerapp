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
- Änderungen an `app/` oder `packages/` bauen zusätzlich per `mobile.yml` die iOS-App für TestFlight und die Android-App für den internen Play-Test.
- Prüfen: `gh run watch`, dann `curl -s https://doener-api.pleasance.org/api/v1/health`.

## Fallen

- Die Adresse `doener-api.pleasance.org` bleibt für ausgelieferte Mobile-Clients erhalten. API-Änderungen müssen mit ihnen kompatibel bleiben.
- Der Maps-JavaScript-Key der Web-Version (`GOOGLE_MAPS_WEB_KEY`) ist per Referrer auf die Domains beschränkt. Neue Domain: Referrer im Google-Projekt ergänzen.
