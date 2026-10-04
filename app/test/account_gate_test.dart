import 'dart:async';
import 'dart:convert';

import 'package:doener_app/src/app.dart';
import 'package:doener_app/src/core/app_data.dart';
import 'package:doener_app/src/core/location.dart';
import 'package:doener_app/src/core/session.dart';
import 'package:doener_app/src/features/social/friends.dart';
import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sembast/sembast_memory.dart';

const _ina = UserDto(id: 'u2', displayName: 'Ina');

class FakeServer {
  String name;
  String? verifiedWithInvite;
  final requests = <String>[];
  FakeServer(this.name);

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path.replaceFirst('/api/v1', '');
    requests.add('${request.method} $path');
    http.Response json(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    switch (path) {
      case '/auth/verify':
        verifiedWithInvite = (jsonDecode(request.body) as Map<String, dynamic>)['inviteCode'] as String?;
        return json(AuthResponse(token: 't', user: UserDto(id: 'u1', displayName: name), isNewUser: true).toJson());
      case '/users/me':
        name = (jsonDecode(request.body) as Map<String, dynamic>)['displayName'] as String;
        return json(UserDto(id: 'u1', displayName: name).toJson());
      case '/me/invite':
        return json(const InviteDto(code: 'mine', url: 'https://doener.test/i/mine').toJson());
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
    child: DoenerApp(onboardingDone: true, invitePromptDone: false, inviteCode: inviteCode, links: links),
  ));
  await tester.pumpAndSettle();
  return (server, db);
}

void main() {
  testWidgets('without an account there is only the login', (tester) async {
    await _pumpApp(tester);
    expect(find.text('Code schicken'), findsOneWidget);
    expect(find.text('Später'), findsNothing);
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
}
