import 'dart:convert';

import 'package:postgres/postgres.dart';

class SmtpConfig {
  final String host;
  final int port;
  final String? username;
  final String? password;
  final bool ssl;
  const SmtpConfig({required this.host, required this.port, this.username, this.password, required this.ssl});
}

class Config {
  final Endpoint database;
  final bool databaseTls;
  final int port;

  /// Public base URL of this server, used for magic links (`$publicUrl/login?token=…`).
  /// Without it, login mails contain only the code.
  final String? publicUrl;
  final String? googlePlacesApiKey;
  final SmtpConfig? smtp;
  final String mailFrom;

  /// Directory with the Flutter web build; served at `/` when it exists.
  final String webDir;

  /// Allowed CORS origin for local web development (e.g. `http://localhost:5000`).
  final String? corsOrigin;

  /// The app link in the mail of an admin's invite (e.g. a public TestFlight link).
  final String? appDownloadUrl;

  /// Where tester feedback is mailed. Without it, feedback is only stored.
  final String? feedbackEmail;

  /// Sign-up stays closed until Robin opens it (`SIGNUP_OPEN=true`): existing
  /// accounts log in, new ones only for [signupAllowlist], a friend's invite
  /// link or an admin's invite.
  final bool signupOpen;
  final Set<String> signupAllowlist;

  /// May invite testers (`ADMIN_EMAILS`). admin@pleasance.org, the agents'
  /// account, never goes in here.
  final Set<String> adminEmails;

  /// App Store Connect key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` as base64)
  /// for the TestFlight group `TESTFLIGHT_GROUP`. Without it, nothing goes to TestFlight.
  final AscConfig? asc;

  /// Commit of the build (`APP_VERSION`); `/health` reports it so the deploy can wait for it.
  final String revision;

  const Config({
    required this.database,
    this.databaseTls = false,
    this.port = 8080,
    this.publicUrl,
    this.googlePlacesApiKey,
    this.smtp,
    this.mailFrom = 'Döner App <noreply@localhost>',
    this.webDir = 'web',
    this.corsOrigin,
    this.appDownloadUrl,
    this.feedbackEmail,
    this.signupOpen = false,
    this.signupAllowlist = const {},
    this.adminEmails = const {},
    this.asc,
    this.revision = 'dev',
  });

  factory Config.fromEnvironment(Map<String, String> env) {
    String? get(String key) {
      final value = env[key]?.trim();
      return (value == null || value.isEmpty) ? null : value;
    }

    Set<String> list(String key) =>
        {for (final entry in (get(key) ?? '').split(',')) if (entry.trim().isNotEmpty) entry.trim().toLowerCase()};

    final smtpHost = get('SMTP_HOST');
    // The image sets APP_ENV=production. Without SMTP the log would hand out login codes and links.
    if (smtpHost == null && get('APP_ENV') == 'production') {
      throw StateError('SMTP_HOST is required in production, otherwise login codes would end up in the log');
    }
    return Config(
      database: Endpoint(
        host: get('DB_HOST') ?? 'localhost',
        port: int.parse(get('DB_PORT') ?? '5432'),
        database: get('DB_NAME') ?? 'doener',
        username: get('DB_USER') ?? 'doener',
        password: get('DB_PASSWORD') ?? 'doener',
      ),
      databaseTls: get('DB_TLS') == 'require',
      port: int.parse(get('PORT') ?? '8080'),
      publicUrl: get('PUBLIC_URL')?.replaceAll(RegExp(r'/+$'), ''),
      googlePlacesApiKey: get('GOOGLE_PLACES_API_KEY'),
      smtp: smtpHost == null
          ? null
          : SmtpConfig(
              host: smtpHost,
              port: int.parse(get('SMTP_PORT') ?? '587'),
              username: get('SMTP_USER'),
              password: get('SMTP_PASSWORD'),
              ssl: get('SMTP_SSL') == 'true',
            ),
      mailFrom: get('MAIL_FROM') ?? 'Döner App <noreply@localhost>',
      webDir: get('WEB_DIR') ?? 'web',
      corsOrigin: get('CORS_ORIGIN'),
      appDownloadUrl: get('APP_DOWNLOAD_URL'),
      feedbackEmail: get('FEEDBACK_EMAIL'),
      signupOpen: get('SIGNUP_OPEN') == 'true',
      signupAllowlist: list('SIGNUP_ALLOWLIST'),
      adminEmails: list('ADMIN_EMAILS'),
      asc: switch ((get('ASC_KEY_ID'), get('ASC_ISSUER_ID'), _pem(get('ASC_KEY_P8')))) {
        (final keyId?, final issuerId?, final key?) =>
          AscConfig(keyId: keyId, issuerId: issuerId, privateKey: key, group: get('TESTFLIGHT_GROUP') ?? 'Erste Tester'),
        _ => null,
      },
      revision: get('APP_VERSION') ?? 'dev',
    );
  }
}

class AscConfig {
  final String keyId;
  final String issuerId;

  /// The .p8 key as PEM.
  final String privateKey;

  /// External TestFlight group that gets the testers and every new build.
  final String group;

  const AscConfig({required this.keyId, required this.issuerId, required this.privateKey, this.group = 'Erste Tester'});
}

/// The .p8 key comes base64 encoded; a PEM pasted as is works too. Anything
/// else turns TestFlight off instead of stopping the server.
String? _pem(String? value) {
  if (value == null || value.contains('BEGIN PRIVATE KEY')) return value;
  try {
    return utf8.decode(base64.decode(value.replaceAll(RegExp(r'\s'), '')));
  } on FormatException {
    print('WARNING: ASC_KEY_P8 is neither base64 nor PEM — TestFlight stays off.');
    return null;
  }
}
