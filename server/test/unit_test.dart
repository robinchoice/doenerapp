import 'dart:convert';

import 'package:doener_models/doener_models.dart';
import 'package:doener_server/doener_server.dart';
import 'package:doener_server/src/google_places.dart';
import 'package:doener_server/src/http.dart';
import 'package:doener_server/src/places.dart';
import 'package:doener_server/src/privacy.dart';
import 'package:doener_server/src/social.dart';
import 'package:http/http.dart' as http;
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

  test('production refuses to start without SMTP', () {
    expect(() => Config.fromEnvironment({'APP_ENV': 'production'}), throwsStateError);
    expect(Config.fromEnvironment({'APP_ENV': 'production', 'SMTP_HOST': 'smtp.test'}).smtp?.host, 'smtp.test');
    expect(Config.fromEnvironment({}).smtp, isNull);
  });

  test('iOS finds the app for invite and review links', () async {
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
    Map<String, dynamic> row({double? sauce, double? fleisch, Map<String, num>? items, bool? ayran, List<String>? ingredients, String? meat, String? bread}) => {
          'sauce_rating': sauce,
          'fleisch_rating': fleisch,
          'brot_rating': null,
          'items': items,
          'ayran_homemade': ayran,
          'ingredients': ingredients,
          'meat': meat,
          'skewer': null,
          'bread': bread,
        };
    final summary = summarize([
      row(sauce: 5, fleisch: 3, items: {'ayran': 5}, ayran: true, ingredients: ['tomate', 'mais', 'granatapfel'], meat: 'kalb', bread: 'homemade'),
      row(sauce: 4, ayran: false, ingredients: ['tomate', 'mais'], meat: 'kalb'),
      row(items: {'falafel': 4}, meat: 'rind'),
    ]);
    expect(summary.items[RatingItem.sauce]!.average, 4.5);
    expect(summary.items[RatingItem.sauce]!.count, 2);
    expect(summary.items[RatingItem.falafel]!.count, 1);
    expect(summary.items.containsKey(RatingItem.brot), isFalse);
    expect(summary.ayranHomemade, isNull, reason: 'one says yes, one says no');
    expect(summary.experts, 2);
    expect(summary.ingredients, [Ingredient.tomate, Ingredient.mais, Ingredient.granatapfel], reason: 'half of the experts is enough');
    expect(summary.specials, [Ingredient.mais, Ingredient.granatapfel]);
    expect(summary.meat, Meat.kalb);
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
    expect(mail.subject, 'Neu in der Döner App: Karte <neu>');
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
}
