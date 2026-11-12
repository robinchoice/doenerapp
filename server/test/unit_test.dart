import 'dart:convert';

import 'package:doener_models/doener_models.dart';
import 'package:doener_server/doener_server.dart';
import 'package:doener_server/src/google_places.dart';
import 'package:doener_server/src/http.dart';
import 'package:doener_server/src/photo_metadata.dart';
import 'package:doener_server/src/places.dart';
import 'package:doener_server/src/privacy.dart';
import 'package:doener_server/src/social.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  test('privacy HTML and Markdown describe current sessions, city storage and push contents', () async {
    final html = await privacyPage(Request('GET', Uri.parse('http://localhost/datenschutz'))).readAsString();
    for (final text in [html, privacyPublicPage(english: false).body]) {
      expect(text, allOf(contains('365 Tage'), contains('verlängert'), contains('speichert deren Namen'),
          contains('Firebase Cloud Messaging'), contains('nur die Art des Ereignisses'), contains('Neuigkeiten per Mail'), contains('Erinnerungen nach einem Besuch plant die App lokal')));
      expect(text, isNot(contains('180 Tage angemeldet')));
    }
  });

  test('health fails while the database is unreachable', () async {
    final config = Config(database: Endpoint(host: 'localhost', port: 1, database: 'doener'), webDir: '/nonexistent');
    final db = openPool(config);
    addTearDown(db.close);
    final handler = buildHandler(Deps(db: db, config: config, mailer: LogMailer(), httpClient: http.Client()));
    final response = await handler(Request('GET', Uri.parse('http://localhost/api/v1/health')));
    expect(response.statusCode, 503);
  });

  test('asks app builds below the minimum to update, but keeps feedback open', () async {
    final config = Config(
      database: Endpoint(host: 'localhost', port: 1, database: 'doener'),
      webDir: '/nonexistent',
      publicUrl: 'https://doener.test',
      appDownloadUrl: 'https://testflight.test/join',
      minBuildIos: 30,
      minBuildAndroid: 20,
    );
    final db = openPool(config);
    addTearDown(db.close);
    final handler = buildHandler(Deps(db: db, config: config, mailer: LogMailer(), httpClient: http.Client()));
    Future<Response> call(String path, [String? platform, String? build, String method = 'GET']) => Future.value(handler(Request(
          method,
          Uri.parse('http://localhost/api/v1/$path'),
          headers: {'x-app-platform': ?platform, 'x-app-build': ?build},
        )));

    final outdated = await call('app', 'ios', '29');
    expect(outdated.statusCode, 426);
    expect(jsonDecode(await outdated.readAsString()), {
      'error': 'Diese Version der App ist zu alt. Bitte aktualisiere sie.',
      'code': 'UPDATE_REQUIRED',
      'url': 'https://testflight.test/join',
    });
    final android = await call('app', 'android', '19');
    expect(jsonDecode(await android.readAsString())['url'], 'https://doener.test/android');
    // Before the login check, so a logged-out old build learns why
    expect((await call('auth/me', 'ios', '29')).statusCode, 426);
    expect((await call('feedback', 'ios', '1', 'POST')).statusCode, 401);
    expect((await call('app', 'ios', '30')).statusCode, 200);
    expect((await call('app', 'android', '20')).statusCode, 200);
    // The web app and local builds send no build number
    expect((await call('app')).statusCode, 200);
    expect((await call('app', 'ios', '0')).statusCode, 200);
  });

  test('production refuses to start without SMTP', () {
    expect(() => Config.fromEnvironment({'APP_ENV': 'production'}), throwsStateError);
    expect(Config.fromEnvironment({'APP_ENV': 'production', 'SMTP_HOST': 'smtp.test'}).smtp?.host, 'smtp.test');
    expect(Config.fromEnvironment({}).smtp, isNull);
    expect(Config.fromEnvironment({'MIN_BUILD_IOS': '42'}).minBuildIos, 42);
    expect(Config.fromEnvironment({}).minBuildAndroid, 0);
    final review = Config.fromEnvironment({'REVIEW_EMAIL': 'Review@Example.org', 'REVIEW_CODE': '424242'});
    expect((review.reviewEmail, review.reviewCode), ('review@example.org', '424242'));
    expect(Config.fromEnvironment({'REVIEW_EMAIL': 'review@example.org', 'REVIEW_CODE': '1234'}).reviewEmail, isNull);
    expect(Config.fromEnvironment({'REVIEW_EMAIL': 'review@example.org'}).reviewEmail, isNull);
    expect(
      Config.fromEnvironment({'REVIEW_EMAIL': 'chef@example.org', 'REVIEW_CODE': '424242', 'ADMIN_EMAILS': 'Chef@example.org'}).reviewEmail,
      isNull,
    );
  });

  test('iOS finds the app for login, invite and review links', () async {
    final config = Config(database: Endpoint(host: 'localhost', port: 1, database: 'doener'), webDir: '/nonexistent');
    final db = openPool(config);
    addTearDown(db.close);
    final handler = buildHandler(Deps(db: db, config: config, mailer: LogMailer(), httpClient: http.Client()));
    final response = await handler(Request('GET', Uri.parse('http://localhost/.well-known/apple-app-site-association')));
    expect(response.statusCode, 200);
    expect(response.mimeType, 'application/json', reason: 'Apple ignores the file with any other type');
    final details = (jsonDecode(await response.readAsString())['applinks']['details'] as List).single;
    expect(details['appIDs'], ['T2F442364K.com.robinchoice.doener']);
    expect(details['components'], [
      {'/': '/i/*'},
      {'/': '/b/*'},
      {'/': '/login'},
    ]);
  });

  test('Android finds the app for invite and review links', () async {
    final config = Config(database: Endpoint(host: 'localhost', port: 1, database: 'doener'), webDir: '/nonexistent');
    final db = openPool(config);
    addTearDown(db.close);
    final handler = buildHandler(Deps(db: db, config: config, mailer: LogMailer(), httpClient: http.Client()));
    final response = await handler(Request('GET', Uri.parse('http://localhost/.well-known/assetlinks.json')));
    expect(response.statusCode, 200);
    expect(response.mimeType, 'application/json');
    final target = (jsonDecode(await response.readAsString()) as List).single['target'];
    expect(target['package_name'], 'com.robinchoice.doener');
    expect(target['sha256_cert_fingerprints'], isNotEmpty);
  });

  test('tiles cover the requested box', () {
    final tiles = tilesCovering(minLat: 47.99, minLon: 7.83, maxLat: 48.02, maxLon: 7.86);
    expect(tiles, hasLength(4));
    for (final t in tiles) {
      expect(t.minLat, lessThanOrEqualTo(48.02));
      expect(t.maxLat, greaterThan(47.99));
    }
    expect(tiles.map((t) => t.key).toSet(), hasLength(4));
  });

  test('a full tile is split into quarters until they hold all shops', () async {
    const tile = Tile(1600, 247);
    final rect = SearchRect.tile(tile);
    final quarters = rect.quarters;
    expect(quarters.map((q) => (q.minLat, q.minLon)).toSet(), hasLength(4));
    expect([quarters.first.minLat, quarters.first.minLon, quarters.last.maxLat, quarters.last.maxLon],
        [tile.minLat, tile.minLon, tile.maxLat, tile.maxLon]);
    expect(quarters.first.maxLat, quarters.last.minLat);

    // Searches around the hotspot are full down to 0.015° and complete below.
    final hotspot = (tile.minLat + 0.001, tile.minLon + 0.001);
    var requests = 0;
    final google = MockClient((request) async {
      requests++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final r = body['locationRestriction']['rectangle'] as Map<String, dynamic>;
      final (low, high) = (r['low'] as Map<String, dynamic>, r['high'] as Map<String, dynamic>);
      final full = (low['latitude'] as num) <= hotspot.$1 && hotspot.$1 < (high['latitude'] as num) &&
          (low['longitude'] as num) <= hotspot.$2 && hotspot.$2 < (high['longitude'] as num) &&
          (high['latitude'] as num) - (low['latitude'] as num) > 0.01;
      final page = body['pageToken'] as String? ?? '0';
      return http.Response(jsonEncode({'places': [], if (full) 'nextPageToken': '${int.parse(page) + 1}'}), 200);
    });
    Future<(bool, int, int)> split({required int splits, int allowed = 99}) async {
      requests = 0;
      var asked = 0;
      final complete = await searchQuarters(google, 'key', rect,
          splits: splits, maySplit: () async => ++asked <= allowed, found: (_) async {});
      return (complete, requests, asked);
    }

    expect(await split(splits: 2), (true, 3 + 3 + 4, 2), reason: 'one full quarter, its quarters are not');
    expect(await split(splits: 1), (true, 3 + 3, 1), reason: 'no deeper than allowed');
    expect(await split(splits: 2, allowed: 1), (false, 3 + 3, 2), reason: 'a refused split leaves shops out');
    expect(await split(splits: 2, allowed: 0), (false, 0, 1));
  });

  test('Google place parsing and döner filter', () {
    final place = GooglePlace.fromJson({
      'id': 'abc',
      'displayName': {'text': 'Bosporus Grill'},
      'location': {'latitude': 48.0, 'longitude': 7.8},
      'types': ['turkish_restaurant', 'restaurant'],
      'addressComponents': [
        {'longText': 'Bertoldstraße', 'types': ['route']},
        {'longText': '12', 'types': ['street_number']},
        {'longText': '79098', 'types': ['postal_code']},
        {'longText': 'Freiburg im Breisgau', 'types': ['locality', 'political']},
      ],
      'regularOpeningHours': {
        'weekdayDescriptions': ['Montag: 11:00–23:00', 'Dienstag: 11:00–23:00'],
      },
    });
    expect(place.address, 'Bertoldstraße 12');
    expect(place.postalCode, '79098');
    expect(place.city, 'Freiburg im Breisgau');
    expect(place.openingHours, 'Montag: 11:00–23:00\nDienstag: 11:00–23:00');
    expect(place.looksLikeDoener, isTrue, reason: 'matched by type, not name');

    final announced = GooglePlace.fromJson({
      'id': 'neu',
      'displayName': {'text': 'Neuer Grill'},
      'location': {'latitude': 48.0, 'longitude': 7.8},
      'businessStatus': 'FUTURE_OPENING',
      'openingDate': {'year': 2026, 'month': 10, 'day': 5},
    });
    expect(announced.openingDate, '2026-10-05');
    expect(announced.isOpenBusiness, isTrue, reason: 'announced places are kept for the news');
    expect(
      GooglePlace.fromJson({
        'id': 'neu',
        'displayName': {'text': 'Neuer Grill'},
        'location': {'latitude': 48.0, 'longitude': 7.8},
        'openingDate': {'year': 2026, 'month': 11},
      }).openingDate,
      '2026-11',
      reason: 'Google may only know the month',
    );

    GooglePlace named(String name) => GooglePlace(id: 'x', name: name, latitude: 0, longitude: 0);
    expect(named('Mustafas Gemüse Kebap').looksLikeDoener, isTrue);
    expect(named('DÖNER HAUS').looksLikeDoener, isTrue);
    expect(named('Pizzeria Roma').looksLikeDoener, isFalse);
  });

  test('feed cursor roundtrip keeps microseconds', () {
    final ts = DateTime.utc(2026, 9, 29, 12, 0, 0, 123, 456);
    const id = '6f1c8a52-3a2b-4c1d-9e8f-0a1b2c3d4e5f';
    final decoded = decodeCursor(encodeCursor(ts, id))!;
    expect(decoded.$1, ts);
    expect(decoded.$2, id);
    expect(() => decodeCursor('not-a-cursor'), throwsA(isA<ApiException>()));
  });

  test('community summary of a place', () {
    expect(summarize(const []).items, isEmpty);
    Map<String, dynamic> row({double? sauce, double? fleisch, Map<String, num>? items, bool? ayran, List<String>? ingredients, List<String>? meats, String? bread}) => {
          'sauce_rating': sauce,
          'fleisch_rating': fleisch,
          'brot_rating': null,
          'items': items,
          'ayran_homemade': ayran,
          'ingredients': ingredients,
          'meats': meats,
          'skewer': null,
          'bread': bread,
        };
    final summary = summarize([
      row(sauce: 5, fleisch: 3, items: {'ayran': 5}, ayran: true, ingredients: ['tomate', 'mais', 'granatapfel'], meats: ['kalb', 'haehnchen'], bread: 'homemade'),
      row(sauce: 4, ayran: false, ingredients: ['tomate', 'mais'], meats: ['kalb']),
      row(items: {'falafel': 4}, meats: ['rind']),
    ]);
    expect(summary.items[RatingItem.sauce]!.average, 4.5);
    expect(summary.items[RatingItem.sauce]!.count, 2);
    expect(summary.items[RatingItem.falafel]!.count, 1);
    expect(summary.items.containsKey(RatingItem.brot), isFalse);
    expect(summary.ayranHomemade, isNull, reason: 'one says yes, one says no');
    expect(summary.experts, 2);
    expect(summary.ingredients, [Ingredient.tomate, Ingredient.mais, Ingredient.granatapfel], reason: 'half of the experts is enough');
    expect(summary.specials, [Ingredient.mais, Ingredient.granatapfel]);
    expect(summary.meats, [Meat.kalb], reason: 'only Kalb is named by at least half');
    expect(summary.bread, Bread.homemade);
  });

  test('news drafts: format and every file in updates/', () {
    final draft = parseDraft('x', '# Neu\n\n- Eins\n- Zwei\n');
    expect(draft.title, 'Neu');
    expect(draft.features, ['Eins', 'Zwei']);
    for (final broken in ['- Eins', '# Neu', '# Neu\nText', '# Neu\n- ${'x' * 301}']) {
      expect(() => parseDraft('x', broken), throwsFormatException, reason: broken);
    }
    expect(readDrafts('../updates'), isNotEmpty);
  });

  test('news mail: escaped HTML, plain text and one-click unsubscribe', () {
    final mail = updateMail(
      const UpdateDto(id: 'u', title: 'Karte <neu>', features: ['Läden & mehr']),
      '11111111-1111-4111-8111-111111111111',
      'https://doener.test',
    );
    expect(mail.subject, 'Neu bei Lieblingsdöner: Karte <neu>');
    expect(mail.html, allOf(contains('Karte &lt;neu&gt;'), contains('Läden &amp; mehr'), isNot(contains('<neu>'))));
    expect(mail.text, contains('Abbestellen: https://doener.test/abmelden?token=11111111-1111-4111-8111-111111111111'));
    expect(mail.headers['List-Unsubscribe'], '<https://doener.test/api/v1/updates/unsubscribe?token=11111111-1111-4111-8111-111111111111>');
    expect(mail.headers['List-Unsubscribe-Post'], 'List-Unsubscribe=One-Click');
  });

  test('city slugs for best-of URLs', () {
    expect(citySlug('Freiburg im Breisgau'), 'freiburg-im-breisgau');
    expect(citySlug('Göttingen'), 'goettingen');
    expect(citySlug(' Frankfurt (Oder) '), 'frankfurt-oder');
  });

  group('stripPhotoMetadata', () {
    List<int> segment(int marker, List<int> payload) => [0xff, marker, (payload.length + 2) >> 8, (payload.length + 2) & 0xff, ...payload];
    // Little-endian TIFF with GPS IFD pointer (0x8825) and orientation 6.
    final tiff = [0x49, 0x49, 0x2a, 0, 8, 0, 0, 0, 2, 0, 0x25, 0x88, 4, 0, 1, 0, 0, 0, 40, 0, 0, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    final scan = [...segment(0xda, [1, 2]), 5, 0xff, 0x00, 6, 0xff, 0xd3, 7];
    final jpeg = [
      0xff, 0xd8,
      ...segment(0xe0, [...'JFIF\x00'.codeUnits, 1, 1]),
      ...segment(0xe1, [...'Exif\x00\x00'.codeUnits, ...tiff]),
      ...segment(0xe1, 'http://ns.adobe.com/xap/1.0/\x00<gps/>'.codeUnits),
      ...segment(0xe2, [...'ICC_PROFILE\x00'.codeUnits, 1]),
      ...segment(0xe2, [...'MPF\x00'.codeUnits, 1]),
      ...segment(0xed, 'Photoshop 3.0\x00'.codeUnits),
      ...segment(0xfe, 'comment'.codeUnits),
      ...segment(0xdb, [0, 1, 2]),
      ...scan,
      ...segment(0xc4, [3]),
      ...scan,
      0xff, 0xd9,
      0xff, 0xd8, 0xff, 0xe1, 0, 4, 1, 2, 0xff, 0xd9, // a second image after the first, as with Motion Photos
    ];

    test('keeps the image and its orientation in a JPEG, nothing else', () {
      final stripped = stripPhotoMetadata(jpeg, 'image/jpeg');
      expect(stripped, [
        0xff, 0xd8,
        ...segment(0xe0, [...'JFIF\x00'.codeUnits, 1, 1]),
        ...segment(0xe1, [...'Exif\x00\x00'.codeUnits, 0x4d, 0x4d, 0, 0x2a, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 6, 0, 0, 0, 0, 0, 0]),
        ...segment(0xe2, [...'ICC_PROFILE\x00'.codeUnits, 1]),
        ...segment(0xdb, [0, 1, 2]),
        ...scan,
        ...segment(0xc4, [3]),
        ...scan,
        0xff, 0xd9,
      ]);
      expect(stripPhotoMetadata(stripped, 'image/jpeg'), stripped, reason: 'stripping twice changes nothing');
    });

    test('drops an EXIF block without orientation completely', () {
      final upright = [0xff, 0xd8, ...segment(0xe1, [...'Exif\x00\x00'.codeUnits, 0x4d, 0x4d, 0, 0x2a, 0, 0, 0, 8, 0, 0]), ...scan, 0xff, 0xd9];
      expect(stripPhotoMetadata(upright, 'image/jpeg'), [0xff, 0xd8, ...scan, 0xff, 0xd9]);
    });

    test('rejects broken JPEGs', () {
      expect(() => stripPhotoMetadata([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3], 'image/jpeg'), throwsFormatException);
      expect(() => stripPhotoMetadata([0xff, 0xd8, ...scan], 'image/jpeg'), throwsFormatException, reason: 'no end');
    });

    List<int> chunk(String type, List<int> data) =>
        [data.length >> 24, data.length >> 16 & 0xff, data.length >> 8 & 0xff, data.length & 0xff, ...type.codeUnits, ...data, 0, 0, 0, 0];

    test('drops text, time and EXIF chunks from a PNG', () {
      final signature = [0x89, ...'PNG\r\n\x1a\n'.codeUnits];
      final png = [
        ...signature,
        ...chunk('IHDR', List.filled(13, 1)),
        ...chunk('eXIf', [1, 2]),
        ...chunk('tEXt', 'GPS\x0048.0'.codeUnits),
        ...chunk('iTXt', [3]),
        ...chunk('zTXt', [3]),
        ...chunk('tIME', [3]),
        ...chunk('IDAT', [4, 5]),
        ...chunk('IEND', []),
      ];
      expect(stripPhotoMetadata(png, 'image/png'),
          [...signature, ...chunk('IHDR', List.filled(13, 1)), ...chunk('IDAT', [4, 5]), ...chunk('IEND', [])]);
    });

    test('drops EXIF and XMP from a WebP and no longer announces them', () {
      List<int> riffChunk(String fourcc, List<int> data) =>
          [...fourcc.codeUnits, data.length & 0xff, data.length >> 8 & 0xff, 0, 0, ...data, if (data.length.isOdd) 0];
      List<int> riff(List<int> body) =>
          [...'RIFF'.codeUnits, (body.length + 4) & 0xff, (body.length + 4) >> 8 & 0xff, 0, 0, ...'WEBP'.codeUnits, ...body];
      final webp = riff([
        ...riffChunk('VP8X', [0x0c, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ...riffChunk('VP8 ', [1, 2, 3]),
        ...riffChunk('EXIF', [1, 2, 3, 4]),
        ...riffChunk('XMP ', [5]),
      ]);
      expect(stripPhotoMetadata(webp, 'image/webp'), riff([...riffChunk('VP8X', List.filled(10, 0)), ...riffChunk('VP8 ', [1, 2, 3])]));
    });
  });
}
