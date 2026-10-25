import 'dart:async';
import 'dart:io';

import 'package:doener_models/doener_models.dart';
import 'package:doener_server/doener_server.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as io;
import 'package:sentry/sentry.dart';

Future<void> main(List<String> args) async {
  // `server login-link <email>`: prints a login link for agent-access/login-link in the kontor.
  if (args.isNotEmpty && args.first == 'login-link') return printLoginLink(args);
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

Future<void> printLoginLink(List<String> args) async {
  if (args.length != 2 || !Validation.isValidEmail(args.last)) {
    stderr.writeln('usage: server login-link <email>');
    exit(1);
  }
  final email = Validation.normalizeEmail(args.last);
  final config = Config.fromEnvironment(Platform.environment);
  final db = openPool(config);
  final httpClient = http.Client();
  print(await loginLink(Deps(db: db, config: config, mailer: LogMailer(), httpClient: httpClient), email));
  httpClient.close();
  await db.close();
}

Future<void> startServer() async {
  // Coolify stops the container with SIGTERM, Ctrl+C sends SIGINT. Watching
  // them before the boot lets it finish first, then the server shuts down.
  final stop = Completer<void>();
  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    signal.watch().listen((_) {
      if (!stop.isCompleted) stop.complete();
    });
  }

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

  final httpClient = http.Client();
  final fcm = config.fcmServiceAccount;
  if (fcm == null) print('WARNING: FCM_SERVICE_ACCOUNT not set — pushes are printed to the log instead of sent.');
  final deps = Deps(
    db: db,
    config: config,
    mailer: mailer,
    httpClient: httpClient,
    pusher: fcm == null ? const LogPusher() : FcmPusher(fcm, httpClient),
  );

  await importDrafts(deps);

  // Every instance polls; the claim in runSchedule lets one of them run it.
  Future<void> runJobs() async {
    try {
      await deleteOldPushEvents(deps);
      await pushPending(deps);
      await deliverUpdateMails(deps);
    } catch (error, stackTrace) {
      print('Pushes or news mails failed: $error');
      await Sentry.captureException(error, stackTrace: stackTrace);
    }
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
  // One run at a time, so the shutdown knows which one to wait for.
  Future<void>? running;
  void runDueJobs() => running ??= runJobs().whenComplete(() => running = null);
  runDueJobs();
  final timer = Timer.periodic(const Duration(minutes: 1), (_) => runDueJobs());
  final server = await io.serve(buildHandler(deps), InternetAddress.anyIPv4, config.port);
  print('Listening on :${server.port}');

  await stop.future;
  print('Shutting down');
  timer.cancel();
  await drain(server);
  await running;
  httpClient.close();
  await db.close();
  await Sentry.close();
  exit(0);
}
