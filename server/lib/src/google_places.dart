import 'dart:convert';

import 'package:http/http.dart' as http;

/// Places are discovered per map tile. A tile is searched at most once per
/// [tileTtl] — the Google cost guard. Empty tiles are remembered as well.
/// The TTL stays below Google's 30-day caching limit for place details.
const tileSizeDeg = 0.03;
const tileTtl = Duration(days: 25);
const maxTilesPerRequest = 16;
const _maxPagesPerTile = 3;

/// Tiles one user may have searched per day; cached tiles don't count.
/// Beyond that, the map only shows places that are already known.
const maxTileSearchesPerDay = 20;

class Tile {
  final int x;
  final int y;
  const Tile(this.x, this.y);

  String get key => '$x:$y';
  double get minLat => y * tileSizeDeg;
  double get maxLat => (y + 1) * tileSizeDeg;
  double get minLon => x * tileSizeDeg;
  double get maxLon => (x + 1) * tileSizeDeg;

  @override
  bool operator ==(Object other) => other is Tile && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(x, y);
}

List<Tile> tilesCovering({
  required double minLat,
  required double minLon,
  required double maxLat,
  required double maxLon,
}) {
  final tiles = <Tile>[];
  for (var y = (minLat / tileSizeDeg).floor(); y <= (maxLat / tileSizeDeg).floor(); y++) {
    for (var x = (minLon / tileSizeDeg).floor(); x <= (maxLon / tileSizeDeg).floor(); x++) {
      tiles.add(Tile(x, y));
    }
  }
  return tiles;
}

class GooglePlace {
  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final List<String> types;
  final String? businessStatus;
  final String? address;
  final String? postalCode;
  final String? city;
  final String? openingHours;

  /// Set for announced openings (status FUTURE_OPENING): `YYYY-MM-DD`, or
  /// `YYYY-MM` when Google only knows the month.
  final String? openingDate;

  const GooglePlace({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.types = const [],
    this.businessStatus,
    this.address,
    this.postalCode,
    this.city,
    this.openingHours,
    this.openingDate,
  });

  factory GooglePlace.fromJson(Map<String, dynamic> j) {
    final components = (j['addressComponents'] as List? ?? []).cast<Map<String, dynamic>>();
    String? component(String type) {
      for (final c in components) {
        if ((c['types'] as List? ?? []).contains(type)) return c['longText'] as String?;
      }
      return null;
    }

    final street = [component('route'), component('street_number')].whereType<String>().join(' ');
    final hours = (j['regularOpeningHours']?['weekdayDescriptions'] as List?)?.cast<String>();
    final opening = j['openingDate'] as Map<String, dynamic>?;
    String two(Object? n) => '$n'.padLeft(2, '0');
    return GooglePlace(
      id: j['id'] as String,
      name: j['displayName']['text'] as String,
      latitude: (j['location']['latitude'] as num).toDouble(),
      longitude: (j['location']['longitude'] as num).toDouble(),
      types: (j['types'] as List? ?? []).cast<String>(),
      businessStatus: j['businessStatus'] as String?,
      address: street.isEmpty ? null : street,
      postalCode: component('postal_code'),
      city: component('locality') ?? component('postal_town'),
      openingHours: hours?.join('\n'),
      openingDate: opening == null
          ? null
          : [opening['year'], two(opening['month']), if (opening['day'] != null) two(opening['day'])].join('-'),
    );
  }

  bool get isOpenBusiness => businessStatus != 'CLOSED_PERMANENTLY';

  static final _namePattern = RegExp(r'd[öo]ner|keba[bp]|dürüm|shawarma|falafel|yufka|lahmacun|imbiss', caseSensitive: false);
  static const _types = {'kebab_shop', 'turkish_restaurant', 'middle_eastern_restaurant', 'lebanese_restaurant'};

  /// Text search already ranks by relevance; this drops the generic
  /// restaurants Google mixes in.
  bool get looksLikeDoener => _namePattern.hasMatch(name) || types.any(_types.contains);
}

// openingDate is in the same price tier as businessStatus.
const _placeFields = [
  'id',
  'displayName',
  'location',
  'types',
  'businessStatus',
  'openingDate',
  'addressComponents',
  'regularOpeningHours',
];
final _fieldMask = [..._placeFields.map((f) => 'places.$f'), 'nextPageToken'].join(',');

/// Place Details (New). Returns null if Google no longer knows the place.
Future<GooglePlace?> fetchPlace(http.Client client, String apiKey, String placeId) async {
  final response = await client.get(
    Uri.parse('https://places.googleapis.com/v1/places/${Uri.encodeComponent(placeId)}?languageCode=de'),
    headers: {'x-goog-api-key': apiKey, 'x-goog-fieldmask': _placeFields.join(',')},
  );
  if (response.statusCode == 404) return null;
  if (response.statusCode != 200) {
    throw http.ClientException('Google Place Details ${response.statusCode}: ${response.body}');
  }
  return GooglePlace.fromJson(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
}

/// Google Places API (New) text search restricted to [tile].
Future<List<GooglePlace>> searchTile(http.Client client, String apiKey, Tile tile) async {
  final results = <GooglePlace>[];
  String? pageToken;
  for (var page = 0; page < _maxPagesPerTile; page++) {
    final response = await client.post(
      Uri.parse('https://places.googleapis.com/v1/places:searchText'),
      headers: {
        'content-type': 'application/json',
        'x-goog-api-key': apiKey,
        'x-goog-fieldmask': _fieldMask,
      },
      body: jsonEncode({
        'textQuery': 'Döner Kebab',
        'languageCode': 'de',
        // Announced openings come with FUTURE_OPENING and their date.
        'includeFutureOpeningBusinesses': true,
        'pageSize': 20,
        'locationRestriction': {
          'rectangle': {
            'low': {'latitude': tile.minLat, 'longitude': tile.minLon},
            'high': {'latitude': tile.maxLat, 'longitude': tile.maxLon},
          },
        },
        'pageToken': ?pageToken,
      }),
    );
    if (response.statusCode != 200) {
      throw http.ClientException('Google Places ${response.statusCode}: ${response.body}');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    results.addAll((body['places'] as List? ?? []).map((p) => GooglePlace.fromJson(p as Map<String, dynamic>)));
    pageToken = body['nextPageToken'] as String?;
    if (pageToken == null) break;
  }
  return results;
}
