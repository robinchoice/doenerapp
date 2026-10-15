import 'dart:async';
import 'dart:io';

import 'package:doener_server/doener_server.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as io;
import 'package:sentry/sentry.dart';

Future<void> main() async {
  await Sentry.init(
    (options) => options
      ..dsn = Platform.environment['SENTRY_DSN'] ?? ''
      ..environment = Platform.environment['SENTRY_ENVIRONMENT'] ?? 'development'
      ..sendDefaultPii = false
      ..maxBreadcrumbs = 0
      ..tracesSampleRate = 0,
    appRunner: startServer,
  );
}

Future<void> startServer() async {
  final config = Config.fromEnvironment(Platform.environment);
  final db = openPool(config);
  await migrate(db);

  final Mailer mailer;
  if (config.smtp != null) {
    mailer = SmtpMailer(config.smtp!, config.mailFrom);
  } else {
    print('WARNING: SMTP_HOST not set — login codes are printed to the log instead of emailed.');
    mailer = LogMailer();
  }
  if (config.googlePlacesApiKey == null) {
    print('WARNING: GOOGLE_PLACES_API_KEY not set — only already known places are returned.');
  }

  final deps = Deps(db: db, config: config, mailer: mailer, httpClient: http.Client());

  // Every instance polls; the claim in runSchedule lets one of them run it.
  Future<void> runDueJobs() async {
    try {
      await runSchedule(db, 'place_cache', const Duration(hours: 24), () => maintainPlaceCache(deps));
    } catch (error, stackTrace) {
      print('Place cache maintenance failed: $error');
      await Sentry.captureException(error, stackTrace: stackTrace);
    }
    try {
      await runSchedule(db, 'best_of', const Duration(hours: 24), () => computeDueBestOf(db));
    } catch (error, stackTrace) {
      print('Best-of lists failed: $error');
      await Sentry.captureException(error, stackTrace: stackTrace);
    }
  }
  unawaited(runDueJobs());
  Timer.periodic(const Duration(minutes: 1), (_) => runDueJobs());
  final server = await io.serve(buildHandler(deps), InternetAddress.anyIPv4, config.port);
  print('Listening on :${server.port}');

  ProcessSignal.sigterm.watch().listen((_) async {
    await server.close();
    await db.close();
    await Sentry.close();
    exit(0);
  });
}
