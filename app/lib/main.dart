import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:sembast/sembast.dart';

import 'src/app.dart';
import 'src/core/app_data.dart';
import 'src/core/db_factory.dart';
import 'src/core/location.dart';
import 'src/core/maps.dart';
import 'src/core/push.dart';
import 'src/core/reminders.dart';
import 'src/core/session.dart';
import 'src/features/social/friends.dart';

Future<void> main() async {
  await SentryFlutter.init(
    (options) => options
      ..dsn = const String.fromEnvironment('SENTRY_DSN')
      ..environment = const String.fromEnvironment('SENTRY_ENVIRONMENT', defaultValue: 'production')
      ..sendDefaultPii = false
      ..maxBreadcrumbs = 0
      ..tracesSampleRate = 0
      ..enableAutoSessionTracking = false,
    appRunner: startApp,
  );
}

Future<void> startApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  await initializeDateFormatting('de');
  await loadGoogleMapsScript(mapsWebKey);

  final db = await openLocalDatabase('doener.db');
  final session = Session(db);
  await session.load();
  final reminders = Reminders.supported ? Reminders(db) : null;
  await reminders?.init();
  Push? push = Push.supported ? Push() : null;
  try {
    await push?.init();
  } catch (e) {
    debugPrint('Push unavailable: $e');
    push = null;
  }
  final data = AppData(db, session, reminders: reminders);
  await data.load();
  final onboardingDone = await settingsStore.record('onboardingDone').get(db) == true;

  // Links opened in the browser: magic link (https://…/login?token=…) and
  // invite (https://…/app?invite=…). The invite is kept until it is accepted —
  // the login via magic link continues in a new tab.
  final linkToken = kIsWeb && Uri.base.path == '/login' ? Uri.base.queryParameters['token'] : null;
  final inviteFromLink = kIsWeb ? Uri.base.queryParameters['invite'] : null;
  if (inviteFromLink != null) await pendingInviteRecord.put(db, inviteFromLink);
  // A shop's review link (https://…/b/<placeId>) leads here as ?review=<placeId>.
  final reviewFromLink = kIsWeb ? Uri.base.queryParameters['review'] : null;
  if (reviewFromLink != null) await data.requestReview(reviewFromLink);
  final inviteCode = await pendingInviteRecord.get(db) as String?;
  final invitePromptDone = await settingsStore.record('invitePromptDone').get(db) == true;

  // Don't block startup on the network.
  session.refresh().then((_) async {
    await data.sync();
    await data.refreshMine();
  });

  runApp(
    MultiProvider(
      providers: [
        Provider<Database>.value(value: db),
        Provider<Reminders?>.value(value: reminders),
        Provider<Push?>.value(value: push),
        ChangeNotifierProvider.value(value: session),
        ChangeNotifierProvider.value(value: data),
        ChangeNotifierProvider(create: (_) => LocationService()),
        ChangeNotifierProvider(create: (_) => Friends(session)),
      ],
      child: DoenerApp(
        onboardingDone: onboardingDone || linkToken != null,
        invitePromptDone: invitePromptDone,
        linkToken: linkToken,
        inviteCode: inviteCode,
        links: kIsWeb ? null : AppLinks().uriLinkStream,
      ),
    ),
  );
}
