@Tags(['db'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:doener_models/doener_models.dart';
import 'package:doener_server/doener_server.dart';
import 'package:doener_server/src/google_places.dart' show maxTileSearchesPerDay;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Runs against a real Postgres. Set TEST_DB_PORT (and optionally
/// TEST_DB_HOST / TEST_DB_USER / TEST_DB_PASSWORD); the database
/// `doener_test` is recreated on every run.
class CapturingMailer implements Mailer {
  final sent = <({String to, String subject, String text, String? replyTo, MailAttachment? attachment})>[];
  @override
  Future<void> send({
    required String to,
    required String subject,
    required String text,
    String? replyTo,
    MailAttachment? attachment,
  }) async =>
      sent.add((to: to, subject: subject, text: text, replyTo: replyTo, attachment: attachment));
}

void main() {
  final env = Platform.environment;
  final port = int.tryParse(env['TEST_DB_PORT'] ?? '');
  if (port == null) {
    test('api tests', () {}, skip: 'TEST_DB_PORT not set');
    return;
  }

  late Handler handler;
  late Handler closedHandler;
  late Deps deps;
  late Pool<void> db;
  final mailer = CapturingMailer();
  var googleCalls = 0;

  setUpAll(() async {
    Endpoint endpoint(String database) => Endpoint(
          host: env['TEST_DB_HOST'] ?? 'localhost',
          port: port,
          database: database,
          username: env['TEST_DB_USER'] ?? 'postgres',
          password: env['TEST_DB_PASSWORD'],
        );
    final admin = await Connection.open(endpoint('postgres'), settings: const ConnectionSettings(sslMode: SslMode.disable));
    await admin.execute('DROP DATABASE IF EXISTS doener_test WITH (FORCE)');
    await admin.execute('CREATE DATABASE doener_test');
    await admin.close();

    final config = Config(
      database: endpoint('doener_test'),
      publicUrl: 'https://doener.test',
      googlePlacesApiKey: 'fake-key',
      webDir: '/nonexistent',
      feedbackEmail: 'robin@doener.test',
      signupOpen: true,
      adminEmails: {'robin@doener.test'},
    );
    db = openPool(config);
    // Leftovers of the Vapor backend, as in production — same names as the new tables.
    await db.execute('CREATE TABLE _fluent_migrations (id uuid PRIMARY KEY)');
    await db.execute('CREATE TABLE users (id uuid PRIMARY KEY, apple_user_id text UNIQUE, display_name text UNIQUE)');
    await db.execute("INSERT INTO users VALUES (gen_random_uuid(), 'apple-1', 'Alter Tester')");
    await migrate(db);
    await migrate(db); // idempotent

    final google = MockClient((request) async {
      googleCalls++;
      if (request.method == 'GET') {
        // Place Details refresh; the announced grill has opened by now.
        final id = request.url.pathSegments.last;
        return http.Response(
          jsonEncode({
            'id': id,
            'displayName': {'text': id == 'place-announced' ? 'Neuer Grill' : 'Kebap Haus'},
            'location': {'latitude': 48.0, 'longitude': 7.85},
            if (id == 'place-announced') 'businessStatus': 'OPERATIONAL',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final low = body['locationRestriction']['rectangle']['low'] as Map<String, dynamic>;
      // Only the tile containing Freiburg's centre has shops.
      final hasShops = (low['latitude'] as num) <= 48.0 && (low['latitude'] as num) + 0.03 > 48.0 &&
          (low['longitude'] as num) <= 7.85 && (low['longitude'] as num) + 0.03 > 7.85;
      final places = hasShops
          ? [
              {
                'id': 'place-kebap',
                'displayName': {'text': 'Kebap Haus'},
                'location': {'latitude': 48.0, 'longitude': 7.85},
                'types': ['restaurant'],
                'addressComponents': [
                  {'longText': 'Berlin', 'types': ['locality']},
                ],
              },
              {
                'id': 'place-pizza',
                'displayName': {'text': 'Pizzeria Roma'},
                'location': {'latitude': 48.001, 'longitude': 7.851},
                'types': ['italian_restaurant'],
              },
              {
                'id': 'place-closed',
                'displayName': {'text': 'Alter Döner'},
                'location': {'latitude': 48.002, 'longitude': 7.852},
                'businessStatus': 'CLOSED_PERMANENTLY',
              },
            ]
          : [];
      return http.Response(jsonEncode({'places': places}), 200, headers: {'content-type': 'application/json'});
    });

    deps = Deps(db: db, config: config, mailer: mailer, httpClient: google);
    handler = buildHandler(deps);
    final closed = Config(
      database: config.database,
      publicUrl: config.publicUrl,
      webDir: config.webDir,
      signupAllowlist: {'liste@example.org'},
      adminEmails: config.adminEmails,
    );
    closedHandler = buildHandler(Deps(db: db, config: closed, mailer: mailer, httpClient: google));
  });

  tearDownAll(() => db.close());

  Future<(int, dynamic)> call(String method, String path, {Object? body, String? token, bool closed = false}) async {
    final response = await (closed ? closedHandler : handler)(Request(
      method,
      Uri.parse('http://localhost/api/v1$path'),
      body: body == null ? null : jsonEncode(body),
      headers: {
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      },
    ));
    final text = await response.readAsString();
    return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  String lastCode() => RegExp(r'Döner App: (\d{6})').firstMatch(mailer.sent.last.text)!.group(1)!;
  String lastLinkToken() => RegExp(r'login\?token=([\w-]+)').firstMatch(mailer.sent.last.text)!.group(1)!;

  Future<(String, UserDto)> signUp(String email, String name) async {
    expect((await call('POST', '/auth/login', body: {'email': email})).$1, 204);
    final (status, body) = await call('POST', '/auth/verify', body: {'email': email, 'code': lastCode()});
    expect(status, 200);
    final auth = AuthResponse.fromJson(body as Map<String, dynamic>);
    final (patched, user) = await call('PATCH', '/users/me', body: {'displayName': name}, token: auth.token);
    expect(patched, 200);
    return (auth.token, UserDto.fromJson(user as Map<String, dynamic>));
  }

  test('old Vapor tables are kept in the legacy schema', () async {
    final rows = await db.execute('SELECT display_name FROM legacy_vapor.users');
    expect(rows.single.single, 'Alter Tester');
    final moved = await db.execute("SELECT count(*)::int FROM pg_tables WHERE schemaname = 'legacy_vapor'");
    expect(moved.single.single, 2);
  });

  test('health checks the database', () async {
    final (status, body) = await call('GET', '/health');
    expect(status, 200);
    expect(body, {'status': 'ok', 'revision': 'dev'});
  });

  group('auth', () {
    test('magic link code flow', () async {
      expect((await call('POST', '/auth/login', body: {'email': 'kaputt'})).$1, 400);
      expect((await call('POST', '/auth/login', body: {'email': ' Anna@Example.org '})).$1, 204);
      expect(mailer.sent.last.to, 'anna@example.org');
      final code = lastCode();

      final wrong = code == '000000' ? '111111' : '000000';
      expect((await call('POST', '/auth/verify', body: {'email': 'anna@example.org', 'code': wrong})).$1, 401);

      final (status, body) = await call('POST', '/auth/verify', body: {'email': 'ANNA@example.org', 'code': code});
      expect(status, 200);
      final auth = AuthResponse.fromJson(body as Map<String, dynamic>);
      expect(auth.isNewUser, isTrue);
      expect(auth.user.displayName, startsWith('Döner-Fan-'));

      // Codes are single-use.
      expect((await call('POST', '/auth/verify', body: {'email': 'anna@example.org', 'code': code})).$1, 401);

      final (meStatus, me) = await call('GET', '/auth/me', token: auth.token);
      expect(meStatus, 200);
      expect(me['id'], auth.user.id);

      expect((await call('POST', '/auth/logout', token: auth.token)).$1, 204);
      expect((await call('GET', '/auth/me', token: auth.token)).$1, 401);
    });

    test('magic link token logs into the existing account', () async {
      await call('POST', '/auth/login', body: {'email': 'anna@example.org'});
      final (status, body) = await call('POST', '/auth/verify', body: {'token': lastLinkToken()});
      expect(status, 200);
      expect(body['isNewUser'], isFalse);
    });

    test('code is locked after too many wrong attempts', () async {
      await call('POST', '/auth/login', body: {'email': 'brute@example.org'});
      final code = lastCode();
      final wrong = code == '000000' ? '111111' : '000000';
      for (var i = 0; i < 5; i++) {
        await call('POST', '/auth/verify', body: {'email': 'brute@example.org', 'code': wrong});
      }
      expect((await call('POST', '/auth/verify', body: {'email': 'brute@example.org', 'code': code})).$1, 401);
    });

    test('login requests are rate limited', () async {
      for (var i = 0; i < 5; i++) {
        expect((await call('POST', '/auth/login', body: {'email': 'spam@example.org'})).$1, 204);
      }
      expect((await call('POST', '/auth/login', body: {'email': 'spam@example.org'})).$1, 429);
    });

    test('diet and expert mode follow the account', () async {
      final (token, _) = await signUp('vera@example.org', 'Vera');
      expect((await call('GET', '/auth/me', token: token)).$2['diet'], 'all');

      final (status, updated) = await call('PATCH', '/users/me', body: {'diet': 'vegan', 'expertMode': true}, token: token);
      expect(status, 200);
      expect(updated['displayName'], 'Vera', reason: 'the name stays');
      final account = AccountDto.fromJson((await call('GET', '/auth/me', token: token)).$2 as Map<String, dynamic>);
      expect(account.diet, Diet.vegan);
      expect(account.expertMode, isTrue);
      expect((await call('PATCH', '/users/me', body: {'diet': 'carnivore'}, token: token)).$1, 400);
    });

    test('display names are unique case-insensitively', () async {
      final (token, _) = await signUp('bert@example.org', 'Bert');
      await signUp('bert2@example.org', 'Bert2');
      final (status, _) = await call('PATCH', '/users/me', body: {'displayName': 'bert2'}, token: token);
      expect(status, 409);
    });
  });

  group('places, visits, reviews, social', () {
    late String anna;
    late String bob;
    late UserDto bobUser;
    late UserDto annaUser;

    setUpAll(() async {
      (anna, annaUser) = await signUp('anna2@example.org', 'Anna');
      (bob, bobUser) = await signUp('bob@example.org', 'Bob');
    });

    test('map area sync filters and caches Google results', () async {
      const bbox = '/places?minLat=47.99&minLon=7.84&maxLat=48.01&maxLon=7.86';
      final (status, body) = await call('GET', bbox, token: anna);
      expect(status, 200);
      expect((body as List).map((p) => p['placeId']), ['place-kebap']);
      expect(body.single['city'], 'Berlin');
      final callsAfterFirst = googleCalls;
      expect(callsAfterFirst, greaterThan(0));

      await call('GET', bbox, token: bob);
      expect(googleCalls, callsAfterFirst, reason: 'tiles are cached, including empty ones');

      expect((await call('GET', '/places?minLat=10&minLon=10&maxLat=5&maxLon=11', token: anna)).$1, 400);
      expect((await call('GET', '/places/unknown')).$1, 404);
    });

    test('Google searches need a login and are capped per user and day', () async {
      final (carl, _) = await signUp('carl@example.org', 'Carl');
      final (dora, _) = await signUp('dora@example.org', 'Dora');
      // Two areas of 4×4 empty tiles — each tile costs exactly one search.
      const first = '/places?minLat=10.001&minLon=10.001&maxLat=10.1&maxLon=10.1';
      const second = '/places?minLat=10.001&minLon=10.121&maxLat=10.1&maxLon=10.22';
      final before = googleCalls;

      expect((await call('GET', first)).$1, 401);
      expect(googleCalls, before);

      expect((await call('GET', first, token: carl)).$1, 200);
      expect((await call('GET', second, token: carl)).$1, 200, reason: 'known places are still served');
      expect(googleCalls - before, maxTileSearchesPerDay);

      // Tiles Carl couldn't search stay open for others.
      expect((await call('GET', second, token: dora)).$1, 200);
      expect(googleCalls - before, 32);
    });

    test('visits are idempotent and only fresh ones go live', () async {
      const id = '11111111-2222-4333-8444-555555555555';
      final visit = {'id': id, 'visitedAt': DateTime.now().toUtc().toIso8601String(), 'foodType': 'yufka'};
      final (created, body) = await call('POST', '/places/place-kebap/visits', body: visit, token: anna);
      expect(created, 201);
      expect(body['placeName'], 'Kebap Haus');
      expect((await call('POST', '/places/place-kebap/visits', body: visit, token: anna)).$1, 200);
      expect((await call('POST', '/places/place-kebap/visits', body: visit, token: bob)).$1, 409);

      final (_, mine) = await call('GET', '/me/visits', token: anna);
      expect(mine, hasLength(1));

      expect(
        (await call('POST', '/places/place-kebap/visits',
                body: {'id': '11111111-2222-4333-8444-555555555556', 'visitedAt': '2020-01-01T12:00:00Z', 'foodType': 'sushi'},
                token: anna))
            .$1,
        400,
      );
      expect(
        (await call('POST', '/places/place-pizza/visits',
                body: {'id': '11111111-2222-4333-8444-555555555557', 'visitedAt': '2020-01-01T12:00:00Z'}, token: anna))
            .$1,
        404,
        reason: 'filtered places were never stored',
      );
      expect((await call('POST', '/places/place-kebap/visits', body: visit)).$1, 401);
    });

    test('friendship: asking back accepts', () async {
      final (_, found) = await call('GET', '/users/search?q=bo', token: anna);
      expect((found as List).map((u) => u['displayName']), contains('Bob'));

      final (s1, f1) = await call('POST', '/friends/requests', body: {'userId': bobUser.id}, token: anna);
      expect(s1, 200);
      expect(f1['status'], 'pending');
      expect(f1['direction'], 'outgoing');

      final (_, bobList) = await call('GET', '/friends', token: bob);
      expect(bobList.single['direction'], 'incoming');

      final (_, f2) = await call('POST', '/friends/requests', body: {'userId': annaUser.id}, token: bob);
      expect(f2['status'], 'accepted');
      expect(f2['id'], f1['id']);

      final (_, live) = await call('GET', '/feed/live', token: bob);
      expect((live as List).single['placeName'], 'Kebap Haus');
      expect(live.single['foodType'], 'yufka');
    });

    test('reviews upsert and feed community data', () async {
      final review = {'sauceRating': 5, 'fleischRating': 4, 'text': 'Top Soße'};
      expect((await call('PUT', '/places/place-kebap/review', body: review, token: anna)).$1, 200);
      final (_, updated) = await call('PUT', '/places/place-kebap/review', body: {...review, 'fleischRating': 5}, token: anna);
      expect(updated['rating'], 5, reason: 'derived from sauce, meat and bread');
      expect(updated['text'], 'Top Soße');
      expect((await call('PUT', '/places/place-kebap/review', body: {'sauceRating': 6}, token: anna)).$1, 400);
      expect((await call('PUT', '/places/place-kebap/review', body: {'ratings': {'sauce': 4.3}}, token: anna)).$1, 400);
      final (_, halves) = await call('PUT', '/places/place-kebap/review', body: {'ratings': {'sauce': 4.5, 'fleisch': 4, 'falafel': 3.5}}, token: anna);
      expect(halves['score'], 4.5, reason: 'the average 4.25 in half steps');
      expect(halves['ratings'], {'sauce': 4.5, 'fleisch': 4.0, 'falafel': 3.5});
      expect([halves['rating'], halves['sauceRating'], halves['items']['falafel']], [5, 5, 4], reason: 'whole numbers for shipped clients');
      await call('PUT', '/places/place-kebap/review', body: {...review, 'fleischRating': 5}, token: anna);

      final (_, place) = await call('GET', '/places/place-kebap');
      expect(place['reviewCount'], 1);
      expect(place['avgRating'], 5.0);

      final (_, summary) = await call('GET', '/places/place-kebap/summary');
      expect(summary['items']['sauce'], {'average': 5.0, 'count': 1});

      final (_, top) = await call('GET', '/places/top?lat=48&lon=7.85');
      expect((top as List).single['placeId'], 'place-kebap');
      final (_, trending) = await call('GET', '/places/trending?lat=48&lon=7.85');
      expect((trending as List).single['placeId'], 'place-kebap');
      expect((await call('GET', '/places/trending')).$1, 400, reason: 'trends are local');
    });

    test('feed pages through many entries without gaps', () async {
      // 30 visits sharing one timestamp — the old feed stopped after 20 and
      // skipped same-second entries.
      final at = DateTime.utc(2026, 1, 1, 12).toIso8601String();
      for (var i = 0; i < 30; i++) {
        final id = '22222222-2222-4222-8222-${i.toString().padLeft(12, '0')}';
        await call('POST', '/places/place-kebap/visits', body: {'id': id, 'visitedAt': at}, token: anna);
      }

      final seen = <String>{};
      String? cursor;
      var pages = 0;
      do {
        final (status, body) = await call('GET', '/feed?limit=20${cursor == null ? '' : '&cursor=$cursor'}', token: bob);
        expect(status, 200);
        final page = FeedPage.fromJson(body as Map<String, dynamic>);
        seen.addAll(page.items.map((i) => i.id));
        cursor = page.cursor;
        pages++;
        expect(page.hasMore, cursor != null);
      } while (cursor != null);

      // 1 fresh visit + 30 backdated visits + 1 review.
      expect(seen, hasLength(32));
      expect(pages, 2);

      final (_, annaFeed) = await call('GET', '/feed', token: anna);
      expect(annaFeed['items'], isEmpty, reason: 'own activity is not in the friends feed');
    });

    test('reviews rate more than the Döner and tell about the place', () async {
      final (status, body) = await call('PUT', '/places/place-kebap/review', token: bob, body: {
        'brotRating': 3,
        'items': {'falafel': 4, 'hummus': 5, 'ayran': 3},
        'ingredients': ['tomate', 'granatapfel'],
        'meat': 'kalb',
      });
      expect(status, 200);
      final review = ReviewDto.fromJson(body as Map<String, dynamic>);
      expect(review.rating, isNull, reason: 'bread alone is no Döner rating');
      expect(review.ratings, {RatingItem.brot: 3, RatingItem.falafel: 4, RatingItem.hummus: 5, RatingItem.ayran: 3});
      expect(review.veganOptions, isTrue, reason: 'Bob rated hummus');
      expect(review.ayranHomemade, isTrue, reason: 'only homemade ayran gets rated');

      final place = PlaceDto.fromJson((await call('GET', '/places/place-kebap')).$2 as Map<String, dynamic>);
      expect(place.score(Diet.all), (average: 5.0, count: 1), reason: "only Anna's review rates the Döner");
      expect(place.score(Diet.vegan), (average: 4.0, count: 1));
      expect(place.score(Diet.vegetarian), (average: 3.5, count: 1), reason: 'falafel and bread');
      expect(place.veganOptions, isTrue);

      final summary = PlaceSummaryDto.fromJson((await call('GET', '/places/place-kebap/summary')).$2 as Map<String, dynamic>);
      expect(summary.items[RatingItem.hummus]!.average, 5);
      expect(summary.ayranHomemade, isTrue);
      expect(summary.ingredients, [Ingredient.tomate, Ingredient.granatapfel]);
      expect(summary.specials, [Ingredient.granatapfel]);
      expect(summary.meat, Meat.kalb);
      expect(summary.experts, 1);

      final (_, reviews) = await call('GET', '/places/place-kebap/reviews');
      final bobs = (reviews as List).map((r) => ReviewDto.fromJson(r as Map<String, dynamic>)).firstWhere((r) => r.userName == 'Bob');
      expect(bobs.ingredients, [Ingredient.tomate, Ingredient.granatapfel]);

      final (_, feed) = await call('GET', '/feed', token: anna);
      final item = FeedPage.fromJson(feed as Map<String, dynamic>).items.firstWhere((i) => i.type == FeedItemType.review);
      expect(item.ratings[RatingItem.hummus], 5, reason: 'friends see what Bob rated');

      Future<int> put(Map<String, dynamic> body) async => (await call('PUT', '/places/place-kebap/review', body: body, token: bob)).$1;
      expect(await put({'items': {'ayran': 3}, 'ayranHomemade': false}), 400);
      expect(await put({'items': {'hummus': 4}, 'veganOptions': false}), 400);
      expect(await put({'items': {'zwiebel': 3}}), 400);
      expect(await put({'ingredients': ['ketchup']}), 400);
      expect(await put({}), 400, reason: 'nothing to save');
      expect(await put({'veganOptions': false}), 200, reason: 'telling there is nothing vegan is enough');
    });

    test('reviews carry a photo and tell who was there', () async {
      final jpeg = [0xff, 0xd8, 0xff, 0xe0, 1, 2, 3];
      final photo = base64.encode(jpeg);
      Future<(int, dynamic)> put(Map<String, dynamic> body) => call('PUT', '/places/place-kebap/review', body: body, token: bob);
      Future<ReviewDto> saved(Map<String, dynamic> body) async {
        final (status, json) = await put(body);
        expect(status, 200, reason: '$json');
        return ReviewDto.fromJson(json as Map<String, dynamic>);
      }

      final first = await saved({'sauceRating': 4, 'photoBase64': photo});
      expect(first.photoId, isNotNull);
      expect(first.onSite, isFalse, reason: 'Bob never checked in here');
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/v1/photos/${first.photoId}')));
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'image/jpeg');
      expect(response.headers['cache-control'], contains('immutable'));
      expect(await response.read().expand((chunk) => chunk).toList(), jpeg);

      expect((await saved({'sauceRating': 5})).photoId, first.photoId, reason: 'an edit without a photo keeps it');
      final replaced = await saved({'sauceRating': 5, 'photoBase64': photo});
      expect(replaced.photoId, allOf(isNotNull, isNot(first.photoId)), reason: 'a new photo gets a new URL');
      expect((await call('GET', '/photos/${first.photoId}')).$1, 404);
      expect((await saved({'sauceRating': 5, 'removePhoto': true})).photoId, isNull);
      expect((await call('GET', '/photos/${replaced.photoId}')).$1, 404);

      expect((await put({'photoBase64': base64.encode([1, 2, 3])})).$1, 400, reason: 'not an image');
      expect((await put({'photoBase64': 'kein Base64!'})).$1, 400);
      expect((await put({'photoBase64': base64.encode([...jpeg, ...List.filled(Validation.reviewPhotoMaxBytes, 0)])})).$1, 413);

      await call('POST', '/places/place-kebap/visits',
          body: {'id': '33333333-2222-4333-8444-555555555555', 'visitedAt': DateTime.now().toUtc().toIso8601String()}, token: bob);
      final withCheckIn = await saved({'photoBase64': photo});
      expect(withCheckIn.photoId, isNotNull, reason: 'a photo alone is a review');
      expect(withCheckIn.onSite, isTrue);

      final (_, reviews) = await call('GET', '/places/place-kebap/reviews');
      final bobs = (reviews as List).map((r) => ReviewDto.fromJson(r as Map<String, dynamic>)).firstWhere((r) => r.userName == 'Bob');
      expect((bobs.photoId, bobs.onSite), (withCheckIn.photoId, true));
      final (_, feed) = await call('GET', '/feed', token: anna);
      final item = FeedPage.fromJson(feed as Map<String, dynamic>).items.firstWhere((i) => i.type == FeedItemType.review);
      expect((item.photoId, item.onSite), (withCheckIn.photoId, true));
      expect((withCheckIn.regular, item.regular), (false, false));

      // Days count by when the server got the check-in: a backdated one or a second on the same day
      // doesn't make a regular, check-ins received on three days do.
      Future<bool> bobIsRegular() async {
        final (_, reviews) = await call('GET', '/places/place-kebap/reviews');
        return (reviews as List).map((r) => ReviewDto.fromJson(r as Map<String, dynamic>)).firstWhere((r) => r.userName == 'Bob').regular;
      }

      for (final (id, daysAgo) in [('33333333-2222-4333-8444-555555555556', 0), ('33333333-2222-4333-8444-555555555557', 5)]) {
        await call('POST', '/places/place-kebap/visits',
            body: {'id': id, 'visitedAt': DateTime.now().toUtc().subtract(Duration(days: daysAgo)).toIso8601String()}, token: bob);
      }
      expect(await bobIsRegular(), isFalse);
      await db.execute("UPDATE visits SET created_at = now() - interval '1 day' WHERE id = '33333333-2222-4333-8444-555555555556'");
      expect(await bobIsRegular(), isFalse, reason: 'two days');
      await db.execute("UPDATE visits SET created_at = now() - interval '2 days' WHERE id = '33333333-2222-4333-8444-555555555557'");
      expect(await bobIsRegular(), isTrue, reason: 'check-ins on $regularVisits days make a regular');
      final (_, feedAgain) = await call('GET', '/feed', token: anna);
      expect(FeedPage.fromJson(feedAgain as Map<String, dynamic>).items.firstWhere((i) => i.type == FeedItemType.review).regular, isTrue);
    });

    test('feedback and shop reports', () async {
      final png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3];
      final feedback = {
        'message': 'Karte ruckelt\nbeim Zoomen',
        'screenshotBase64': base64.encode(png),
        'appVersion': '1.0.0',
        'buildNumber': '42',
        'platform': 'iOS',
      };
      expect((await call('POST', '/feedback', body: feedback, token: bob)).$1, 204);
      final mail = mailer.sent.last;
      expect(mail.to, 'robin@doener.test');
      expect(mail.subject, 'Feedback von Bob: Karte ruckelt');
      expect(mail.replyTo, 'bob@example.org');
      expect(mail.text, allOf(contains('Karte ruckelt\nbeim Zoomen'), contains('Bob <bob@example.org>'), contains('1.0.0 (42), iOS')));
      expect(mail.attachment?.fileName, 'screenshot.png');
      expect(mail.attachment?.contentType, 'image/png');
      expect(mail.attachment?.bytes, png);

      expect((await call('POST', '/feedback', body: {'message': 'Ohne Bild'}, token: bob)).$1, 204);
      expect(mailer.sent.last.attachment, isNull);
      expect((await call('POST', '/feedback', body: {'message': 'x'}, token: bob)).$1, 400);
      final stored = await db.execute('SELECT count(*)::int, count(screenshot)::int FROM feedback');
      expect(stored.first, [2, 1]);
      expect((await call('POST', '/shop-reports', body: {'name': 'Erbil', 'latitude': 48.0}, token: bob)).$1, 204);
      final rows = await db.execute('SELECT count(*)::int FROM shop_reports');
      expect(rows.first.first, 1);
    });

    test('deleting the account removes the user data', () async {
      expect((await call('DELETE', '/users/me', token: anna)).$1, 204);
      expect((await call('GET', '/auth/me', token: anna)).$1, 401);
      final (_, place) = await call('GET', '/places/place-kebap');
      expect(place['reviewCount'], 0);
      final (_, friends) = await call('GET', '/friends', token: bob);
      expect(friends, isEmpty);
    });
  });

  group('community around a city', () {
    // A city of its own, far away from the places of the other tests.
    late String ute;
    late String vic;
    late String wim;
    late UserDto vicUser;

    Future<void> place(String id, String name, double lat, String city) => db.execute(
          Sql.named('INSERT INTO places (google_place_id, name, latitude, longitude, city) '
              'VALUES (@id, @name, @lat, 8.0, @city)'),
          parameters: {'id': id, 'name': name, 'lat': lat, 'city': city},
        );

    Future<void> review(String token, String placeId, Map<String, dynamic> ratings) async {
      final (status, _) = await call('PUT', '/places/$placeId/review', body: ratings, token: token);
      expect(status, 200);
    }

    List<String> ids(dynamic places) => [for (final p in places as List) p['placeId'] as String];

    setUpAll(() async {
      late UserDto uteUser;
      (ute, uteUser) = await signUp('ute@example.org', 'Ute');
      (vic, vicUser) = await signUp('vic@example.org', 'Vic');
      (wim, _) = await signUp('wim@example.org', 'Wim');
      // Ute and Vic are friends, Wim is a stranger to both.
      await call('POST', '/friends/requests', body: {'userId': vicUser.id}, token: ute);
      await call('POST', '/friends/requests', body: {'userId': uteUser.id}, token: vic);

      await place('t-steady', 'Steady Kebap', 50.0, 'Testheim');
      await place('t-solo', 'Solo Döner', 50.01, 'Testheim');
      await place('t-meh', 'Meh Imbiss', 50.02, 'Testheim');
      await place('t-new', 'Neuer Laden', 50.001, 'Testheim');
      await place('t-far', 'Fern Grill', 50.5, 'Fernstadt'); // 55 km away

      // Döner scores 5 (4.5 rounded), 4 and 5 for Steady; sauces 4 and 3.
      await review(ute, 't-steady', {'sauceRating': 4, 'fleischRating': 5});
      await review(vic, 't-steady', {'sauceRating': 3, 'fleischRating': 5});
      await review(wim, 't-steady', {'fleischRating': 5});
      await review(wim, 't-solo', {'sauceRating': 5, 'fleischRating': 5});
      await review(ute, 't-meh', {'fleischRating': 2});
      await review(wim, 't-meh', {'fleischRating': 2});
      await review(wim, 't-far', {'fleischRating': 5});
    });

    test('ranking is per city and weighted', () async {
      final (status, body) = await call('GET', '/ranking?lat=50&lon=8', token: ute);
      expect(status, 200);
      final ranking = RankingDto.fromJson(body as Map<String, dynamic>);
      expect(ranking.city, 'Testheim');
      // A single 5 doesn't beat 5, 5 and 4; unrated and other cities' places are left out.
      expect(ranking.entries.map((e) => e.place.placeId), ['t-steady', 't-solo', 't-meh']);
      expect(ranking.entries.first.average, closeTo(4.5, 1e-9), reason: '4.5, 4 and 5');
      expect(ranking.entries.first.count, 3);
      expect(ranking.by, RankBy.overall);
      expect(ranking.entries.first.friends.map((f) => (f.user.displayName, f.rating)), [('Vic', 4)]);
      expect(ranking.entries[1].friends, isEmpty, reason: 'Wim is no friend');

      final (_, sauce) = await call('GET', '/ranking?lat=50&lon=8&by=sauce', token: ute);
      final bySauce = RankingDto.fromJson(sauce as Map<String, dynamic>);
      expect(bySauce.entries.map((e) => e.place.placeId), ['t-solo', 't-steady']);
      expect(bySauce.entries[1].friends.single.rating, 3);

      final (_, nowhere) = await call('GET', '/ranking?lat=10&lon=10', token: ute);
      expect(nowhere['city'], isNull);
      expect(nowhere['entries'], isEmpty);
      expect((await call('GET', '/ranking?lat=50&lon=8&by=zwiebel', token: ute)).$1, 400);
      expect((await call('GET', '/ranking?lat=50&lon=8')).$1, 401);
    });

    test('top places are weighted and filled up with unrated ones nearby', () async {
      final (_, top) = await call('GET', '/places/top?lat=50&lon=8&limit=3');
      expect(ids(top), ['t-steady', 't-solo', 't-meh']);
      final (_, more) = await call('GET', '/places/top?lat=50&lon=8&limit=5');
      expect(ids(more), ['t-steady', 't-solo', 't-meh', 't-new'], reason: 'Fern Grill is beyond 10 km');
      expect(more.last['reviewCount'], 0);
    });

    test('trends are local', () async {
      final (_, trending) = await call('GET', '/places/trending?lat=50&lon=8');
      expect(ids(trending), ['t-steady', 't-meh', 't-solo']);
    });

    test('feed: friends everywhere, everyone else\'s reviews around', () async {
      await call('POST', '/places/t-far/visits',
          body: {'id': '44444444-4444-4444-8444-444444444444', 'visitedAt': DateTime.now().toUtc().toIso8601String()},
          token: vic);

      final (_, around) = await call('GET', '/feed?lat=50&lon=8', token: ute);
      final items = FeedPage.fromJson(around as Map<String, dynamic>).items;
      expect(
        items.map((i) => (i.type, i.user.displayName, i.place.placeId, i.fromFriend)).toSet(),
        {
          (FeedItemType.visit, 'Vic', 't-far', true),
          (FeedItemType.review, 'Vic', 't-steady', true),
          (FeedItemType.review, 'Wim', 't-steady', false),
          (FeedItemType.review, 'Wim', 't-solo', false),
          (FeedItemType.review, 'Wim', 't-meh', false),
        },
        reason: 'own reviews and strangers far away are left out',
      );

      final (_, friendsOnly) = await call('GET', '/feed', token: ute);
      expect((friendsOnly['items'] as List).map((i) => i['user']['displayName']).toSet(), {'Vic'});
    });

    test('rankings for vegans and single dishes', () async {
      final (xen, _) = await signUp('xen@example.org', 'Xen');
      await review(xen, 't-meh', {'brotRating': 4, 'items': {'falafel': 5, 'veganSauce': 5}});
      await review(vic, 't-steady', {'sauceRating': 3, 'fleischRating': 5, 'items': {'falafel': 3}});

      final (_, body) = await call('GET', '/ranking?lat=50&lon=8&by=vegan', token: ute);
      final vegan = RankingDto.fromJson(body as Map<String, dynamic>);
      expect(vegan.by, const RankBy.score(Diet.vegan));
      expect(vegan.entries.map((e) => e.place.placeId), ['t-meh', 't-steady']);
      expect(vegan.entries.first.average, closeTo(4.5, 1e-9), reason: 'falafel, sauce and bread: 4.67, stored as 4.5');
      expect(vegan.entries[1].friends.single.rating, 3, reason: "Vic's falafel");

      final (_, falafel) = await call('GET', '/ranking?lat=50&lon=8&by=falafel', token: ute);
      expect([for (final e in falafel['entries'] as List) (e['place']['placeId'], e['average'])], [('t-meh', 5.0), ('t-steady', 3.0)]);

      final (_, overall) = await call('GET', '/ranking?lat=50&lon=8', token: ute);
      expect((overall['entries'] as List).first['count'], 3, reason: "Xen's review has no Döner score");

      final (_, top) = await call('GET', '/places/top?lat=50&lon=8&limit=3&by=vegan');
      expect(ids(top), ['t-meh', 't-steady', 't-new'], reason: 'filled up with the nearest unrated place');
      expect((await call('GET', '/places/top?lat=50&lon=8&by=sauce')).$1, 400, reason: 'top lists go by main scores');

      // Yan found nothing vegan at Steady: the falafel there wasn't vegan then.
      final (yan, _) = await signUp('yan@example.org', 'Yan');
      await review(yan, 't-steady', {'veganOptions': false, 'items': {'falafel': 5}});
      final (_, after) = await call('GET', '/ranking?lat=50&lon=8&by=vegan', token: ute);
      expect([for (final e in after['entries'] as List) (e['place']['placeId'], e['count'])], [('t-meh', 1), ('t-steady', 1)]);
      final (_, veganTop) = await call('GET', '/places/top?lat=50&lon=8&limit=3&by=vegan');
      expect(ids(veganTop), ['t-meh', 't-new', 't-solo'], reason: 'most say there is nothing vegan at Steady');
    });

    test('"eating now" lasts an hour', () async {
      final ninetyMinutesAgo = DateTime.now().toUtc().subtract(const Duration(minutes: 90));
      await call('DELETE', '/me/live-status', token: vic);
      await call('POST', '/places/t-steady/visits',
          body: {'id': '55555555-5555-4555-8555-555555555555', 'visitedAt': ninetyMinutesAgo.toIso8601String()},
          token: vic);
      expect((await call('GET', '/feed/live', token: ute)).$2, isEmpty);

      await call('POST', '/places/t-steady/visits',
          body: {'id': '55555555-5555-4555-8555-555555555556', 'visitedAt': DateTime.now().toUtc().toIso8601String()},
          token: vic);
      final (_, live) = await call('GET', '/feed/live', token: ute);
      final until = DateTime.parse((live as List).single['until'] as String);
      expect(until.difference(DateTime.now()).inMinutes, inInclusiveRange(58, 60));
    });
  });

  test('landing page in both languages', () async {
    Future<String> page(String path) async => (await handler(Request('GET', Uri.parse('http://localhost$path')))).readAsString();
    expect(await page('/'), contains('Der beste Döner'));
    expect(await page('/en'), contains('The best döner'));
  });

  test('tester requests mail Robin once per address and platform', () async {
    expect((await call('POST', '/tester-requests', body: {'email': 'no-mail', 'platform': 'ios'})).$1, 400);
    expect((await call('POST', '/tester-requests', body: {'email': 'tim@example.org', 'platform': 'windows'})).$1, 400);

    final before = mailer.sent.length;
    expect((await call('POST', '/tester-requests', body: {'email': ' Tim@Example.org', 'platform': 'android'})).$1, 204);
    final mail = mailer.sent.last;
    expect(mail.to, 'robin@doener.test');
    expect(mail.subject, 'Testanfrage Android: tim@example.org');
    expect(mail.replyTo, 'tim@example.org');

    expect((await call('POST', '/tester-requests', body: {'email': 'tim@example.org', 'platform': 'android'})).$1, 204);
    expect((await call('POST', '/tester-requests', body: {'email': 'tim@example.org', 'platform': 'ios'})).$1, 204);
    expect(mailer.sent.length, before + 2, reason: 'the repeated Android request sends no second mail');
  });

  group('closed sign-up', () {
    Future<(int, dynamic)> login(String email, {String? inviteCode}) =>
        call('POST', '/auth/login', body: {'email': email, 'inviteCode': ?inviteCode}, closed: true);
    Future<(int, dynamic)> verify(String email, {String? inviteCode}) => call('POST', '/auth/verify',
        body: {'email': email, 'code': lastCode(), 'inviteCode': ?inviteCode}, closed: true);

    test('strangers get a message in both languages and no mail', () async {
      final before = mailer.sent.length;
      final (status, body) = await login('fremd@example.org');
      expect(status, 403);
      expect(body['error'], allOf(contains('Registrierung ist noch geschlossen'), contains('Sign-up is still closed')));
      expect(mailer.sent.length, before);
      expect((await login('fremd@example.org', inviteCode: 'unknown')).$1, 403, reason: 'an unknown code opens nothing');
    });

    test('tester requests from before the closing still sign up', () async {
      await call('POST', '/tester-requests', body: {'email': 'frueh@example.org', 'platform': 'ios'});
      await call('POST', '/tester-requests', body: {'email': 'spaet@example.org', 'platform': 'ios'});
      await db.execute("UPDATE tester_requests SET created_at = '2026-10-15 13:00+00' WHERE email = 'frueh@example.org'");
      await db.execute("UPDATE tester_requests SET created_at = '2026-10-15 15:00+00' WHERE email = 'spaet@example.org'");
      expect((await login('frueh@example.org')).$1, 204);
      expect((await verify('frueh@example.org')).$2['isNewUser'], isTrue);
      expect((await login('spaet@example.org')).$1, 403);
    });

    test('existing accounts and the allowlist log in', () async {
      await signUp('bestand@example.org', 'Bestand');
      expect((await login('Bestand@example.org')).$1, 204);
      expect((await verify('bestand@example.org')).$2['isNewUser'], isFalse);

      expect((await login(' Liste@Example.org ')).$1, 204);
      expect((await verify('liste@example.org')).$2['isNewUser'], isTrue);
    });

    test("a friend's invite link lets a new address in", () async {
      final (frieda, _) = await signUp('frieda@example.org', 'Frieda');
      final code = (await call('GET', '/me/invite', token: frieda)).$2['code'] as String;
      expect((await login('freund@example.org', inviteCode: code)).$1, 204);
      final (status, body) = await verify('freund@example.org', inviteCode: code);
      expect(status, 200);
      expect(body['isNewUser'], isTrue);

      // The magic link carries only the token, the login request remembers the code.
      expect((await login('link@example.org', inviteCode: code)).$1, 204);
      final (linkStatus, link) = await call('POST', '/auth/verify', body: {'token': lastLinkToken()}, closed: true);
      expect(linkStatus, 200);
      expect(link['isNewUser'], isTrue);

      // A reset link stops working between login and verify.
      expect((await login('spaeter@example.org', inviteCode: code)).$1, 204);
      await call('POST', '/me/invite/reset', token: frieda);
      expect((await verify('spaeter@example.org', inviteCode: code)).$1, 403, reason: 'verify checks again');
    });

    test('admins invite testers, everyone else may not', () async {
      final (robin, _) = await signUp('robin@doener.test', 'Robin');
      final (gast, _) = await signUp('gast@example.org', 'Gast');
      expect((await call('GET', '/auth/me', token: robin)).$2['admin'], isTrue);
      expect((await call('GET', '/auth/me', token: gast)).$2['admin'], isFalse);

      expect((await call('POST', '/auth/invite', body: {'email': 'tess@example.org'})).$1, 401);
      expect((await call('POST', '/auth/invite', body: {'email': 'tess@example.org'}, token: gast)).$1, 403);
      expect((await call('POST', '/auth/invite', body: {'email': 'kaputt'}, token: robin)).$1, 400);
      expect((await call('POST', '/auth/invite', body: {'email': ' Tess@Example.org'}, token: robin, closed: true)).$1, 204);
      expect(mailer.sent.last.to, 'tess@example.org');
      expect(mailer.sent.last.subject, 'Robin lädt dich in die Döner App ein');

      final (status, body) = await verify('tess@example.org');
      expect(status, 200);
      expect(body['isNewUser'], isFalse, reason: 'the invite created the account');
      expect((await login('tess@example.org')).$1, 204, reason: 'logs in like any account later on');
      expect((await call('POST', '/auth/invite', body: {'email': 'tess@example.org'}, token: robin)).$1, 204,
          reason: 'inviting twice mails again');
    });
  });

  group('invites', () {
    test('opening the link makes friends without a request', () async {
      final (ina, inaUser) = await signUp('ina@example.org', 'Ina');
      final (status, invite) = await call('GET', '/me/invite', token: ina);
      expect(status, 200);
      final code = invite['code'] as String;
      expect(invite['url'], 'https://doener.test/i/$code');
      expect((await call('GET', '/me/invite', token: ina)).$2['code'], code, reason: 'stays until reset');
      expect((await call('GET', '/invites/$code')).$2['displayName'], 'Ina');

      // A new account remembers whose link brought it in.
      await call('POST', '/auth/login', body: {'email': 'jan@example.org'});
      final (_, auth) = await call('POST', '/auth/verify', body: {'email': 'jan@example.org', 'code': lastCode(), 'inviteCode': code});
      final jan = auth['token'] as String;
      final invitedBy = await db.execute(
        Sql.named('SELECT invited_by FROM users WHERE id = @id:uuid'),
        parameters: {'id': auth['user']['id']},
      );
      expect(invitedBy.single.single, inaUser.id);

      final (accepted, friendship) = await call('POST', '/invites/$code/accept', token: jan);
      expect(accepted, 200);
      expect(friendship['status'], 'accepted');
      expect(friendship['user']['id'], inaUser.id);
      final (_, inasFriends) = await call('GET', '/friends', token: ina);
      expect((inasFriends as List).single['status'], 'accepted');
      expect((await call('POST', '/invites/$code/accept', token: jan)).$1, 200, reason: 'opening it twice is harmless');

      expect((await call('POST', '/invites/$code/accept', token: ina)).$1, 400);
      expect((await call('POST', '/invites/$code/accept')).$1, 401);
      expect((await call('POST', '/invites/unknown/accept', token: jan)).$1, 404);
    });

    test('the link settles an open request, a reset kills the old link', () async {
      final (kai, kaiUser) = await signUp('kai@example.org', 'Kai');
      final (lea, _) = await signUp('lea@example.org', 'Lea');
      await call('POST', '/friends/requests', body: {'userId': kaiUser.id}, token: lea);

      final (_, invite) = await call('GET', '/me/invite', token: kai);
      final (_, friendship) = await call('POST', '/invites/${invite['code']}/accept', token: lea);
      expect(friendship['status'], 'accepted');

      final (_, fresh) = await call('POST', '/me/invite/reset', token: kai);
      expect(fresh['code'], isNot(invite['code']));
      expect((await call('GET', '/invites/${invite['code']}')).$1, 404);
      expect((await call('GET', '/invites/${fresh['code']}')).$1, 200);
    });

    test('invite page previews the inviter without injecting markup', () async {
      final (nora, _) = await signUp('nora@example.org', '<i>Nora</i>');
      final code = (await call('GET', '/me/invite', token: nora)).$2['code'] as String;

      Future<(int, String)> page(String path) async {
        final response = await handler(Request('GET', Uri.parse('http://localhost$path')));
        return (response.statusCode, await response.readAsString());
      }

      final (status, html) = await page('/i/$code');
      expect(status, 200);
      expect(html, contains('<meta property="og:title" content="&lt;i&gt;Nora&lt;/i&gt; lädt dich in die Döner App ein">'));
      expect(html, isNot(contains('<i>Nora')));
      expect(html, contains('<meta property="og:image" content="https://doener.test/icons/Icon-512.png">'));
      expect(html, contains('href="/app?invite=$code"'));

      final (missing, notFound) = await page('/i/%3Cscript%3E');
      expect(missing, 404);
      expect(notFound, isNot(contains('<script')));
    });

    test('review link and poster of a shop', () async {
      Future<(int, String)> page(String path) async {
        final response = await handler(Request('GET', Uri.parse('http://localhost$path')));
        return (response.statusCode, await response.readAsString());
      }

      final (status, html) = await page('/b/place-kebap');
      expect(status, 200);
      expect(html, contains('Kebap Haus'));
      expect(html, contains('href="/app?review=place-kebap"'));
      expect(html, contains('Ortsdaten: Google Maps'));

      final (posterStatus, poster) = await page('/aushang/place-kebap');
      expect(posterStatus, 200);
      expect(poster, contains('<svg'));
      expect(poster, contains('https://doener.test/b/place-kebap'));

      final (unknownStatus, unknown) = await page('/b/place-unknown');
      expect(unknownStatus, 200, reason: 'a poster outlives the 30-day cache; the app loads the shop again');
      expect(unknown, allOf(contains('href="/app?review=place-unknown"'), isNot(contains('Ortsdaten'))));
      expect((await page('/b/%3Cscript%3E')).$1, 404);
      expect((await page('/aushang/%3Cscript%3E')).$1, 404);

      expect((await call('GET', '/places/place-gone')).$1, 404, reason: 'Google only for signed-in users');
      final (plakat, _) = await signUp('poster@example.org', 'Plakat');
      final (status2, gone) = await call('GET', '/places/place-gone', token: plakat);
      expect((status2, gone['name']), (200, 'Kebap Haus'));
    });
  });

  test('place cache stays within Google\'s 30 days', () async {
    final (carla, _) = await signUp('carla@example.org', 'Carla');
    await call('POST', '/places/place-kebap/visits',
        body: {'id': '33333333-3333-4333-8333-333333333333', 'visitedAt': '2026-01-01T12:00:00Z'}, token: carla);
    await db.execute("INSERT INTO places (google_place_id, name, latitude, longitude) VALUES ('place-unused', 'Alt', 48, 7.85)");
    await db.execute("UPDATE places SET synced_at = now() - interval '31 days', name = 'Veraltet' "
        "WHERE google_place_id IN ('place-kebap', 'place-unused')");

    await maintainPlaceCache(deps);

    final (_, kept) = await call('GET', '/places/place-kebap');
    expect(kept['name'], 'Kebap Haus', reason: 'visited place is refreshed from Google');
    expect((await call('GET', '/places/place-unused')).$1, 404, reason: 'unused stale place is dropped');
  });

  test('a schedule runs once per period, and again an hour after a failed run', () async {
    var runs = 0;
    Future<void> run() => runSchedule(db, 'place_cache', const Duration(hours: 24), () async => runs++);
    await Future.wait([run(), run()]);
    expect(runs, 1, reason: 'claimed by one instance only');
    await run();
    expect(runs, 1, reason: 'not due again yet');
    final next = await db.execute("SELECT next_run_at > now() + interval '23 hours' FROM schedules WHERE name = 'place_cache'");
    expect(next.first.first, isTrue);

    await db.execute("UPDATE schedules SET next_run_at = now() WHERE name = 'place_cache'");
    await expectLater(runSchedule(db, 'place_cache', const Duration(hours: 24), () => throw StateError('down')), throwsStateError);
    final retry = await db.execute("SELECT next_run_at BETWEEN now() + interval '59 minutes' AND now() + interval '1 hour' "
        "FROM schedules WHERE name = 'place_cache'");
    expect(retry.first.first, isTrue);
  });

  test('announced openings become news once they open', () async {
    await db.execute("INSERT INTO places (google_place_id, name, latitude, longitude, city, business_status, opening_date) VALUES "
        "('place-announced', 'Neuer Grill', 48.003, 7.853, 'Freiburg', 'FUTURE_OPENING', to_char(current_date, 'YYYY-MM-DD')), "
        "('place-later', 'Später Grill', 48.004, 7.854, 'Freiburg', 'FUTURE_OPENING', '2099-01')");
    final before = NewPlacesDto.fromJson((await call('GET', '/places/new?lat=48&lon=7.85')).$2 as Map<String, dynamic>);
    expect(before.opened, isEmpty);
    expect(before.upcoming.map((p) => p.placeId), ['place-announced', 'place-later']);
    expect(before.upcoming.last.opensOn, '2099-01');
    expect((await call('GET', '/places/place-announced')).$1, 404, reason: 'not open yet');

    await maintainPlaceCache(deps);

    final after = NewPlacesDto.fromJson((await call('GET', '/places/new?lat=48&lon=7.85')).$2 as Map<String, dynamic>);
    expect(after.opened.single.placeId, 'place-announced');
    expect(after.opened.single.openedOn, isNotNull);
    expect(after.upcoming.single.placeId, 'place-later', reason: 'checked only from the announced day on');
    expect((await call('GET', '/places/place-announced')).$1, 200);
  });

  test('editing an older review keeps its overall rating', () async {
    final (ida, idaUser) = await signUp('ida@example.org', 'Ida');
    await db.execute(
      Sql.named("INSERT INTO reviews (user_id, place_id, rating) SELECT @user:uuid, id, 4 FROM places WHERE google_place_id = 'place-kebap'"),
      parameters: {'user': idaUser.id},
    );
    final (_, kept) = await call('PUT', '/places/place-kebap/review', body: {'text': 'Immer noch gut'}, token: ida);
    expect(kept['rating'], 4, reason: 'no sauce, meat or bread to derive it from');
    final (_, derived) = await call('PUT', '/places/place-kebap/review', body: {'sauceRating': 2}, token: ida);
    expect(derived['rating'], 2, reason: 'rated Döner items take over');
  });
}
