# One image for the API server and the Flutter web app it serves.
# Build from the repo root: docker build -t doener .

# Web output is platform-independent — build it natively on the build host.
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS web
RUN apt-get update && apt-get install -y --no-install-recommends git curl unzip xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 -b 3.47.5 https://github.com/flutter/flutter.git /flutter
ENV PATH=/flutter/bin:$PATH
RUN flutter config --no-analytics --enable-web && flutter precache --web
WORKDIR /src
COPY packages ./packages
COPY app/pubspec.* ./app/
RUN cd app && flutter pub get
COPY app ./app
# Self-host CanvasKit and fonts instead of loading them from Google's CDN.
# Referrer-restricted browser key; it ends up in the public JS anyway.
ARG GOOGLE_MAPS_WEB_KEY=""
ARG SENTRY_DSN=""
# Firebase browser key for push, referrer-restricted like the Maps key.
ARG FIREBASE_WEB_KEY=""
RUN cd app && flutter build web --release --no-web-resources-cdn --dart-define=GOOGLE_MAPS_WEB_KEY=$GOOGLE_MAPS_WEB_KEY \
    --dart-define=SENTRY_DSN=$SENTRY_DSN --dart-define=FIREBASE_API_KEY=$FIREBASE_WEB_KEY \
    && sed -i "s/FIREBASE_WEB_KEY/$FIREBASE_WEB_KEY/" build/web/firebase-messaging-sw.js

FROM dart:3.13 AS server
WORKDIR /src
COPY packages ./packages
COPY server/pubspec.* ./server/
RUN cd server && dart pub get
COPY server ./server
RUN cd server && dart compile exe bin/server.dart -o /server

FROM scratch
COPY --from=server /runtime/ /
# Outgoing TLS (Google Places, SMTP) needs the CA bundle.
COPY --from=server /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
# Coolify's healthcheck runs through /bin/sh with curl or wget. Busybox picks the applet by file name.
COPY --from=busybox:1.37-musl /bin/busybox /bin/sh
COPY --from=busybox:1.37-musl /bin/busybox /bin/wget
COPY --from=server /server /app/server
COPY --from=web /src/app/build/web /app/web
ARG APP_VERSION=dev
# APP_ENV=production makes SMTP_HOST mandatory; the local compose overrides it.
ENV WEB_DIR=/app/web PORT=8080 APP_ENV=production APP_VERSION=$APP_VERSION
EXPOSE 8080
ENTRYPOINT ["/app/server"]
