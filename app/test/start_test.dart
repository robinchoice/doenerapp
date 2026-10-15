import 'dart:convert';

import 'package:doener_app/src/core/app_data.dart';
import 'package:doener_app/src/core/location.dart';
import 'package:doener_app/src/core/session.dart';
import 'package:doener_app/src/features/place/check_in_sheet.dart';
import 'package:doener_app/src/features/ranking/ranking_screen.dart';
import 'package:doener_app/src/features/social/friends.dart';
import 'package:doener_app/src/features/start/start_screen.dart';
import 'package:doener_app/src/ui/widgets.dart';
import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:sembast/sembast_memory.dart';

const _me = AccountDto(id: 'u1', displayName: 'Robin');
const _tom = UserDto(id: 'u2', displayName: 'Tom');
const _ina = UserDto(id: 'u3', displayName: 'Ina');
const _rated = PlaceDto(placeId: 'p1', name: 'Kebap Haus', latitude: 48, longitude: 7.85, avgRating: 4.5, reviewCount: 4);
const _unrated = PlaceDto(placeId: 'p2', name: 'Neuer Laden', latitude: 48.001, longitude: 7.85);
const _meatOnly = PlaceDto(placeId: 'p3', name: 'Fleischerei Grill', latitude: 48.002, longitude: 7.85, veganOptions: false);

class FakeServer {
  final requests = <Uri>[];

  Iterable<Uri> calls(String path) => requests.where((u) => u.path == '/api/v1$path');

  Future<http.Response> handle(http.Request request) async {
    requests.add(request.url);
    http.Response json(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    final now = DateTime.now().toUtc();
    final path = request.url.path.replaceFirst('/api/v1', '');
    if (path.endsWith('/visits')) {
      final body = CreateVisitRequest.fromJson(jsonDecode(request.body) as Map<String, dynamic>);
      return json(VisitDto(
        id: body.id,
        userId: _me.id,
        userName: _me.displayName,
        placeId: request.url.pathSegments[3],
        placeName: 'Laden',
        visitedAt: body.visitedAt,
        foodType: body.foodType,
      ).toJson());
    }
    return switch (path) {
      '/auth/verify' => json(const AuthResponse(token: 't', user: _me, isNewUser: false).toJson()),
      '/users/me' => json(AccountDto(
          id: _me.id,
          displayName: _me.displayName,
          diet: Diet.values.byName((jsonDecode(request.body) as Map<String, dynamic>)['diet'] as String),
        ).toJson()),
      '/places/new' => json(NewPlacesDto(
          opened: [PlaceDto(placeId: 'p4', name: 'Anatolia Grill', latitude: 48, longitude: 7.86, city: 'Freiburg', openedOn: DateTime(2026, 10, 2))],
          upcoming: const [PlaceDto(placeId: 'p5', name: 'Grillhaus Dreisam', latitude: 48, longitude: 7.87, opensOn: '2026-10-15')],
        ).toJson()),
      '/places/top' => json([_rated.toJson(), _unrated.toJson()]),
      '/feed' => json(FeedPage(hasMore: false, items: [
          FeedItem(id: 'v1', type: FeedItemType.visit, user: _tom, place: _rated, timestamp: now, fromFriend: true, foodType: 'yufka'),
          FeedItem(id: 'r1', type: FeedItemType.review, user: _ina, place: _rated, timestamp: now, fromFriend: false, ratings: const {RatingItem.sauce: 4}),
        ]).toJson()),
      '/ranking' => json(RankingDto(
          city: 'Freiburg im Breisgau',
          by: RankBy.parse(request.url.queryParameters['by']!)!,
          entries: [
            RankingEntryDto(place: _rated, average: 4.5, count: 4, friends: [FriendRatingDto(user: _tom, rating: 5)]),
            const RankingEntryDto(place: _meatOnly, average: 3.5, count: 2),
          ],
          bestOf: request.url.queryParameters['by'] == 'vegan'
              ? null
              : const BestOfDto(year: 2026, city: 'Freiburg im Breisgau', category: BestOfCategory.overall, path: '/bestenliste/freiburg-im-breisgau/2026', entries: [
                  BestOfEntryDto(rank: 1, placeId: 'b1', name: 'Bosporus Grill'),
                  BestOfEntryDto(rank: 2, placeId: 'b2', name: 'Mardin Döner'),
                  BestOfEntryDto(rank: 3, placeId: 'b3', name: 'Yufka-Ecke'),
                ]),
        ).toJson()),
      _ => json([]),
    };
  }
}

/// [child] with a signed-in session and the app's providers.
Future<FakeServer> _pump(WidgetTester tester, Widget child, {LatLng? position}) async {
  tester.view.physicalSize = const Size(1170, 6000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  FlutterSecureStorage.setMockInitialValues({});
  final server = FakeServer();
  final (db, session) = (await tester.runAsync(() async {
    final db = await newDatabaseFactoryMemory().openDatabase('start.db');
    final session = Session(db, httpClient: MockClient(server.handle));
    await session.load();
    await session.verify(const VerifyRequest(email: 'r@example.org', code: '123456'));
    return (db, session);
  }))!;

  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: session),
      ChangeNotifierProvider(create: (_) => AppData(db, session)),
      ChangeNotifierProvider(create: (_) => LocationService()..position = position),
      ChangeNotifierProvider(create: (_) => Friends(session)),
    ],
    child: MaterialApp(home: child),
  ));
  await tester.pumpAndSettle();
  return server;
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('start shows the best places around, marks friends and helps newcomers', (tester) async {
    final server = await _pump(tester, StartScreen(onOpenMap: () {}), position: const LatLng(48, 7.85));

    expect(find.text('Kebap Haus'), findsOneWidget);
    expect(find.text('noch unbewertet'), findsOneWidget);
    expect(find.text('Bewerte deinen Stammladen'), findsOneWidget);
    expect(find.text('Hol deine Freunde per QR-Code'), findsOneWidget);
    expect(find.text('Dönerneuling · Eingecheckt bei Kebap Haus', findRichText: true), findsOneWidget, reason: 'the tier leads the line');
    expect(find.text('Dönerneuling · Bewertet: Kebap Haus', findRichText: true), findsOneWidget);
    expect(find.byIcon(Icons.group), findsOneWidget, reason: 'only Tom is a friend');
    expect(find.text('🎉 Neu in Freiburg'), findsOneWidget);
    expect(find.text('Anatolia Grill hat am 2. Oktober aufgemacht'), findsOneWidget);
    expect(find.text('🗓️ Bald: Grillhaus Dreisam. Laut Google am 15. Oktober'), findsOneWidget);
    expect(server.calls('/feed').single.queryParameters['lat'], '48.0');

    await tester.tap(find.text('Nur Freunde'));
    await tester.pumpAndSettle();
    expect(server.calls('/feed').last.queryParameters.containsKey('lat'), isFalse);
  });

  testWidgets('ranking shows the city, the friends per place and switches dimensions', (tester) async {
    final server = await _pump(tester, const RankingScreen(), position: const LatLng(48, 7.85));

    expect(find.text('Ranking Freiburg im Breisgau'), findsOneWidget);
    expect(find.text('Tom 5'), findsOneWidget);
    expect(find.text('4,5'), findsOneWidget);
    expect(server.calls('/ranking').single.queryParameters['by'], 'overall');
    expect(find.text('Die besten Döner in Freiburg im Breisgau 2026'), findsOneWidget);
    expect(find.text('Mardin Döner'), findsOneWidget);

    await tester.tap(find.text('Soße'));
    await tester.pumpAndSettle();
    expect(server.calls('/ranking').last.queryParameters['by'], 'sauce');
    expect(find.text('Fleischerei Grill'), findsOneWidget);
  });

  testWidgets('vegans rank by vegan food and miss the places without any', (tester) async {
    final server = await _pump(tester, const RankingScreen(), position: const LatLng(48, 7.85));
    final session = tester.element(find.byType(RankingScreen)).read<Session>();
    await tester.runAsync(() => session.updateSettings(diet: Diet.vegan));
    await tester.pumpAndSettle();

    expect(server.calls('/ranking').last.queryParameters['by'], 'vegan');
    expect(find.text('Vegan-Ranking Freiburg im Breisgau'), findsOneWidget);
    expect(find.text('Fleisch'), findsNothing);
    expect(find.text('Kebap Haus'), findsOneWidget);
    expect(find.text('Fleischerei Grill'), findsNothing, reason: 'people found nothing vegan there');
    expect(find.textContaining('Am 1. Januar erscheint die Bestenliste'), findsOneWidget, reason: 'no vegan list yet');
  });

  testWidgets('check-in lets the user pick between shops next to each other', (tester) async {
    final server = await _pump(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showAppSheet(context, (_) => const CheckInSheet(places: [_rated, _unrated])),
              child: const Text('Öffnen'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: 'check-ins come without a comment');

    await tester.tap(find.text('Neuer Laden'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.check));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(server.calls('/places/p2/visits'), hasLength(1));
    expect(find.text('Einchecken'), findsNothing, reason: 'the sheet closes');
  });
}
