import 'dart:io';

import 'package:doener_server/doener_server.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:sentry/sentry.dart';

/// Background jobs, as their own container from the API image. Schedules live
/// in Postgres, so any number of workers can run side by side.
Future<void> main() async {
  await Sentry.init(
    (options) => options
      ..dsn = Platform.environment['SENTRY_DSN'] ?? ''
      ..environment = Platform.environment['SENTRY_ENVIRONMENT'] ?? 'development'
      ..sendDefaultPii = false
      ..maxBreadcrumbs = 0
      ..tracesSampleRate = 0,
    appRunner: startWorker,
  );
}

Future<void> startWorker() async {
  final config = Config.fromEnvironment(Platform.environment, needsMail: false);
  final db = openPool(config);
  await migrate(db);
  final deps = Deps(db: db, config: config, mailer: LogMailer(), httpClient: http.Client());

  // For Coolify's healthcheck: the process is up.
  final health = await io.serve(
    (Request request) => request.url.path == 'health' ? Response.ok('ok') : Response.notFound(null),
    InternetAddress.anyIPv4,
    config.port,
  );
  print('Worker listening on :${health.port}');

  ProcessSignal.sigterm.watch().listen((_) async {
    await health.close();
    await db.close();
    await Sentry.close();
    exit(0);
  });

  while (true) {
    try {
      await runSchedule(db, 'place_cache', const Duration(hours: 24), () => maintainPlaceCache(deps));
    } catch (error, stackTrace) {
      print('Place cache maintenance failed: $error');
      await Sentry.captureException(error, stackTrace: stackTrace);
    }
    await Future<void>.delayed(const Duration(minutes: 1));
  }
}
