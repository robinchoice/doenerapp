import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:doener_app/src/app.dart';
import 'package:doener_app/src/core/app_data.dart';
import 'package:doener_app/src/core/location.dart';
import 'package:doener_app/src/core/session.dart';
import 'package:doener_app/src/features/social/friends.dart';
import 'package:doener_app/src/features/ranking/ranking_screen.dart';
import 'package:doener_app/src/features/place/review_sheet.dart';
import 'package:doener_app/src/ui/widgets.dart';
import 'package:doener_app/src/features/start/start_screen.dart';
import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:sembast/sembast_memory.dart';

const _ina = UserDto(id: 'u2', displayName: 'Ina');

class FakeServer {
  String name;
  String? verifiedWithInvite;
  String? loginWithInvite;
  Map<String, dynamic>? feedback;
  final requests = <String>[];
  FakeServer(this.name);

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path.replaceFirst('/api/v1', '');
    requests.add('${request.method} $path');
    http.Response json(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    switch (path) {
      case '/auth/login':
        loginWithInvite = (jsonDecode(request.body) as Map<String, dynamic>)['inviteCode'] as String?;
        return http.Response('', 204);
      case '/auth/verify':
        verifiedWithInvite = (jsonDecode(request.body) as Map<String, dynamic>)['inviteCode'] as String?;
        return json(AuthResponse(token: 't', user: AccountDto(id: 'u1', displayName: name), isNewUser: true).toJson());
      case '/users/me':
        name = (jsonDecode(request.body) as Map<String, dynamic>)['displayName'] as String;
        return json(UserDto(id: 'u1', displayName: name).toJson());
      case '/feed':
        return json({'items': [], 'hasMore': false});
      case '/ranking':
        return json(RankingDto(by: RankBy.parse(request.url.queryParameters['by'] ?? 'overall')!, entries: const []).toJson());
      case '/me/invite':
        return json(const InviteDto(code: 'mine', url: 'https://doener.test/i/mine').toJson());
      case '/feedback':
        feedback = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('', 204);
      case '/invites/abc':
        return json(_ina.toJson());
      case '/invites/abc/accept':
        return json(FriendshipDto(
          id: 'f1',
          user: _ina,
          status: FriendshipStatus.accepted,
          direction: FriendshipDirection.incoming,
          createdAt: DateTime.utc(2026),
        ).toJson());
    }
    return json([]);
  }
}

/// The app as `main()` builds it, minus platform services.
Future<(FakeServer, Database)> _pumpApp(
  WidgetTester tester, {
  bool loggedIn = false,
  bool invitePromptDone = false,
  String name = 'Döner-Fan-1234',
  String? inviteCode,
  Stream<Uri>? links,
}) async {
  // Phone-sized screen; the default 800×600 cuts off the login form.
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  FlutterSecureStorage.setMockInitialValues({});
  final server = FakeServer(name);
  final (db, session) = (await tester.runAsync(() async {
    final db = await newDatabaseFactoryMemory().openDatabase('gate.db');
    final session = Session(db, httpClient: MockClient(server.handle));
    await session.load();
    if (loggedIn) await session.verify(const VerifyRequest(email: 'r@example.org', code: '123456'));
    if (inviteCode != null) await pendingInviteRecord.put(db, inviteCode);
    return (db, session);
  }))!;

  await tester.pumpWidget(MultiProvider(
    providers: [
      Provider<Database>.value(value: db),
      ChangeNotifierProvider.value(value: session),
      ChangeNotifierProvider(create: (_) => AppData(db, session)),
      ChangeNotifierProvider(create: (_) => LocationService()),
      ChangeNotifierProvider(create: (_) => Friends(session)),
    ],
    child: DoenerApp(onboardingDone: true, invitePromptDone: invitePromptDone, inviteCode: inviteCode, links: links),
  ));
  await tester.pumpAndSettle();
  return (server, db);
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('tabs retain their state across window sizes and a short rail scrolls', (tester) async {
    await _pumpApp(tester, loggedIn: true, name: 'Robin', invitePromptDone: true);
    await tester.tap(find.text('Ranking').last);
    await tester.pumpAndSettle();
    final ranking = tester.state(find.byType(RankingScreen));
    final start = tester.state(find.byType(StartScreen, skipOffstage: false));
    for (final size in [const Size(1024, 768), const Size(900, 320), const Size(320, 640), const Size(768, 1024)]) {
      tester.view.physicalSize = size * 3;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$size');
      expect(tester.state(find.byType(RankingScreen)), same(ranking), reason: '$size');
      expect(tester.state(find.byType(StartScreen, skipOffstage: false)), same(start));
      if (size.width >= 900) {
        await tester.ensureVisible(find.text('Profil').last);
        await tester.pumpAndSettle();
        expect(find.text('Profil').last.hitTestable(), findsOneWidget);
      }
    }
    tester.view.physicalSize = const Size(1024, 768) * 3;
    for (final bounds in [const Rect.fromLTWH(500, 0, 24, 768), const Rect.fromLTWH(0, 360, 1024, 24)]) {
      tester.view.displayFeatures = [ui.DisplayFeature(bounds: bounds, type: ui.DisplayFeatureType.hinge, state: ui.DisplayFeatureState.postureHalfOpened)];
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.state(find.byType(RankingScreen)), same(ranking));
      expect(tester.getRect(find.byWidgetPredicate((w) => w is NavigationBar || w is NavigationRail)).overlaps(bounds), isFalse);
    }
    tester.view.displayFeatures = [];
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(RankingScreen)), same(ranking));
  });

  testWidgets('review draft survives resize and remains reachable above keyboard and safe areas', (tester) async {
    await _pumpApp(tester, loggedIn: true, name: 'Robin', invitePromptDone: true);
    showAppSheet(tester.element(find.byType(StartScreen)), (_) => const ReviewSheet(
      place: PlaceDto(placeId: 'p1', name: 'Testladen', latitude: 48, longitude: 7.85),
    ));
    await tester.pumpAndSettle();
    final field = find.byType(TextField).first;
    await tester.ensureVisible(field);
    await tester.enterText(field, '7,50');
    final draft = tester.state(find.byType(ReviewSheet));
    for (final size in [const Size(1024, 768), const Size(844, 390), const Size(320, 640)]) {
      tester.view.physicalSize = size * 3;
      tester.view.viewInsets = const FakeViewPadding(bottom: 600);
      tester.view.viewPadding = const FakeViewPadding(top: 72, bottom: 60, left: 36, right: 36);
      tester.view.padding = const FakeViewPadding(top: 72, left: 36, right: 36);
      await tester.pumpAndSettle();
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$size');
      expect(tester.state(find.byType(ReviewSheet)), same(draft));
      expect(tester.widget<TextField>(field).controller!.text, '7,50');
      expect(tester.getRect(field).bottom, lessThanOrEqualTo(size.height - 200));
      expect(find.byTooltip('Schließen').hitTestable(), findsOneWidget);
    }
    tester.view.viewInsets = const FakeViewPadding();
    tester.view.padding = const FakeViewPadding(top: 72, bottom: 60, left: 36, right: 36);
    await tester.pumpAndSettle();
    final sheet = tester.getRect(find.byType(ReviewSheet));
    expect(sheet.bottom, lessThanOrEqualTo(620));
  });

  testWidgets('an expired session leaves Start before storage cleanup finishes', (tester) async {
    final (_, db) = await _pumpApp(tester, loggedIn: true, name: 'Robin', invitePromptDone: true);
    expect(find.byType(StartScreen), findsOneWidget);
    final context = tester.element(find.byType(StartScreen));
    final session = context.read<Session>();
    final location = context.read<LocationService>();
    var loggedOutNotified = false;
    session.addListener(() => loggedOutNotified = !session.isLoggedIn);

    session.api.onUnauthorized!();
    expect(loggedOutNotified, isTrue, reason: 'the login gate must rebuild before storage cleanup awaits');
    location.notifyListeners();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(StartScreen), findsNothing);
    expect(find.text('Code schicken'), findsOneWidget);
    expect(session.expired, isTrue);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => settingsStore.record('user').get(db)), isNull);
  });

  testWidgets('without an account there is only the login', (tester) async {
    await _pumpApp(tester);
    expect(find.text('Code schicken'), findsOneWidget);
    expect(find.text('Später'), findsNothing);
    expect(find.byIcon(Icons.bug_report_outlined), findsNothing, reason: 'feedback needs an account');
  });

  testWidgets('a tap outside a text field closes the keyboard', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tapAt(const Offset(20, 20));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('the bug button sends feedback with a screenshot of the screen', (tester) async {
    PackageInfo.setMockInitialValues(appName: 'Lieblingsdöner', packageName: 'doener', version: '1.0.0', buildNumber: '42', buildSignature: '');
    final (server, _) = await _pumpApp(tester, loggedIn: true, name: 'Robin');

    // The screenshot is rendered for real, outside the test's fake clock.
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.bug_report_outlined));
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pumpAndSettle();
    expect(find.text('Screenshot entfernen'), findsOneWidget);
    expect(find.byIcon(Icons.bug_report_outlined), findsNothing, reason: 'hidden while the form is open');

    await tester.enterText(find.byType(TextField).last, 'Karte ruckelt');
    await tester.pump();
    await tester.tap(find.text('Senden'));
    await tester.pumpAndSettle();
    expect(server.feedback?['message'], 'Karte ruckelt');
    expect(base64.decode(server.feedback!['screenshotBase64'] as String).take(4), [0x89, 0x50, 0x4e, 0x47], reason: 'PNG');
    expect(find.text('Danke für dein Feedback!'), findsOneWidget);
    // The tap's handler runs outside the fake clock and continues there.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.byIcon(Icons.bug_report_outlined), findsOneWidget);
  });

  testWidgets('the placeholder name has to go before the app opens', (tester) async {
    await _pumpApp(tester, loggedIn: true);
    expect(find.text('Wie heißt du?'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Döner-Fan-99');
    await tester.tap(find.text('Weiter'));
    await tester.pumpAndSettle();
    expect(find.text('Bitte wähle einen eigenen Namen.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Robin');
    await tester.tap(find.text('Weiter'));
    await tester.pumpAndSettle();
    expect(find.text('Hol deine Döner-Crew dazu'), findsOneWidget);
    expect(find.text('https://doener.test/i/mine'), findsOneWidget);
  });

  testWidgets('signing up through an invite names the inviter and passes the code on', (tester) async {
    final (server, _) = await _pumpApp(tester, inviteCode: 'abc');
    expect(find.textContaining('Ina hat dich eingeladen'), findsOneWidget);

    Future<void> submit() async {
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
    }

    await tester.enterText(find.byType(TextField), 'robin@example.org');
    await submit();
    await tester.enterText(find.byType(TextField).last, '123456');
    await submit();

    expect(server.loginWithInvite, 'abc', reason: 'the link lets a new address past the closed sign-up');
    expect(server.verifiedWithInvite, 'abc');
    expect(find.text('Wie heißt du?'), findsOneWidget);
    expect(server.requests, isNot(contains('POST /invites/abc/accept')), reason: 'friends only meet the chosen name');
  });

  testWidgets('a pending invite is accepted once the account has a name', (tester) async {
    final (server, db) = await _pumpApp(tester, loggedIn: true, name: 'Robin', inviteCode: 'abc');
    expect(server.requests, contains('POST /invites/abc/accept'));
    expect(find.text('Du bist jetzt mit Ina befreundet.'), findsOneWidget);
    expect(await tester.runAsync(() => pendingInviteRecord.get(db)), isNull);
  });

  testWidgets('an invite link opened in the app makes friends right away', (tester) async {
    final links = StreamController<Uri>();
    final (server, _) = await _pumpApp(tester, loggedIn: true, name: 'Robin', links: links.stream);

    links.add(Uri.parse('https://doener-api.pleasance.org/i/abc'));
    await tester.pumpAndSettle();
    expect(server.requests, contains('POST /invites/abc/accept'));
    expect(find.text('Du bist jetzt mit Ina befreundet.'), findsOneWidget);
  });

  testWidgets('an invite link opened before the login names the inviter', (tester) async {
    final links = StreamController<Uri>();
    final (server, _) = await _pumpApp(tester, links: links.stream);

    links.add(Uri.parse('https://doener-api.pleasance.org/i/abc'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ina hat dich eingeladen'), findsOneWidget);
    expect(server.requests, isNot(contains('POST /invites/abc/accept')));
  });

  testWidgets('a login link opened in the app logs in there', (tester) async {
    final links = StreamController<Uri>();
    final (server, _) = await _pumpApp(tester, name: 'Robin', inviteCode: 'abc', links: links.stream);

    links.add(Uri.parse('https://doener-api.pleasance.org/login?token=xyz'));
    await tester.pumpAndSettle();
    expect(server.requests, contains('POST /auth/verify'));
    expect(server.verifiedWithInvite, 'abc');
    expect(find.text('Code schicken'), findsNothing);
  });
}
