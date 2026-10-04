import 'dart:convert';

import 'package:doener_server/doener_server.dart';
import 'package:doener_server/src/google_places.dart';
import 'package:doener_server/src/http.dart';
import 'package:doener_server/src/places.dart';
import 'package:doener_server/src/social.dart';
import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  test('health fails while the database is unreachable', () async {
    final config = Config(database: Endpoint(host: 'localhost', port: 1, database: 'doener'), webDir: '/nonexistent');
    final db = openPool(config);
    addTearDown(db.close);
    final handler = buildHandler(Deps(db: db, config: config, mailer: LogMailer(), httpClient: http.Client()));
    final response = await handler(Request('GET', Uri.parse('http://localhost/api/v1/health')));
    expect(response.statusCode, 503);
  });

  test('iOS finds the app for invite links', () async {
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
    ]);
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

  test('summary text', () {
    expect(summarize(const [], null).summaryText, 'Noch keine Bewertungen.');
    final summary = summarize([
      {'rating': 5, 'sauce_rating': 5, 'fleisch_rating': 3, 'brot_rating': null, 'text': 'Beste Soße der Stadt'},
      {'rating': 4, 'sauce_rating': 4, 'fleisch_rating': null, 'brot_rating': null, 'text': null},
    ], 'Knoblauchsoße');
    expect(summary.reviewCount, 2);
    expect(summary.avgRating, 4.5);
    expect(summary.topDimension, 'Soße');
    expect(summary.avgBrotRating, isNull);
    expect(
      summary.summaryText,
      '2 Bewertungen, insgesamt ausgezeichnet (4.5/5). Soße wird besonders gelobt (4.5/5). '
      'Bekannt für: Knoblauchsoße. „Beste Soße der Stadt“',
    );
  });
}
