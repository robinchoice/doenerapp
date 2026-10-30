import 'dart:convert';

import 'package:doener_models/doener_models.dart';
import 'package:http/http.dart' as http;

/// A tile is searched at most once per [tileTtl] — the Google cost guard.
/// Empty tiles are remembered as well. The TTL stays below Google's 30-day
/// caching limit for place details.
const tileTtl = Duration(days: 25);

/// A text search returns at most this many pages of 20 places.
const maxPagesPerSearch = 3;

/// Searches one user may start per day: one per tile, four per split of a
/// full one; cached tiles don't count. Beyond that, the map only shows places
/// that are already known and the response carries [searchLimitHeader].
const maxTileSearchesPerDay = 20;

/// How often a full tile is split into quarters: twice gives searches of
/// about 0.8 × 0.5 km, each again with up to 60 places.
const maxTileSplits = 2;

/// The rectangle one text search covers. A full one gets split into [quarters].
class SearchRect {
  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;
  const SearchRect(this.minLat, this.minLon, this.maxLat, this.maxLon);

  SearchRect.tile(Tile t) : this(t.minLat, t.minLon, t.maxLat, t.maxLon);

  List<SearchRect> get quarters {
    final lat = (minLat + maxLat) / 2;
    final lon = (minLon + maxLon) / 2;
    return [
      SearchRect(minLat, minLon, lat, lon),
      SearchRect(minLat, lon, lat, maxLon),
      SearchRect(lat, minLon, maxLat, lon),
      SearchRect(lat, lon, maxLat, maxLon),
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is SearchRect && other.minLat == minLat && other.minLon == minLon && other.maxLat == maxLat && other.maxLon == maxLon;
  @override
  int get hashCode => Object.hash(minLat, minLon, maxLat, maxLon);
}

/// A square of [size]×[size] tiles from tile ([x], [y]). The prefetch splits
/// a full one into [quarters] down to single tiles.
class TileBlock {
  final int x;
  final int y;
  final int size;
  const TileBlock(this.x, this.y, [this.size = 1]);

  double get minLat => y * tileSizeDeg;
  double get maxLat => (y + size) * tileSizeDeg;
  double get minLon => x * tileSizeDeg;
  double get maxLon => (x + size) * tileSizeDeg;
  SearchRect get rect => SearchRect(minLat, minLon, maxLat, maxLon);

  List<Tile> get tiles => [
        for (var dy = 0; dy < size; dy++)
          for (var dx = 0; dx < size; dx++) Tile(x + dx, y + dy),
      ];

  List<TileBlock> get quarters {
    final half = size ~/ 2;
    return [
      TileBlock(x, y, half),
      TileBlock(x + half, y, half),
      TileBlock(x, y + half, half),
      TileBlock(x + half, y + half, half),
    ];
  }

  @override
  bool operator ==(Object other) => other is TileBlock && other.x == x && other.y == y && other.size == size;
  @override
  int get hashCode => Object.hash(x, y, size);
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

// The fields decide the price: these are all billed as Pro, openingDate
// included. Opening hours would make every search Enterprise (fewer free
// requests, higher price), so only Place Details asks for them.
const _searchFields = ['id', 'displayName', 'location', 'types', 'businessStatus', 'openingDate', 'addressComponents'];
const _placeFields = [..._searchFields, 'regularOpeningHours'];
final _fieldMask = [..._searchFields.map((f) => 'places.$f'), 'nextPageToken'].join(',');

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

typedef SearchResult = ({List<GooglePlace> places, bool full, int requests});

/// Google Places API (New) text search restricted to [rect]. Full when
/// Google had more than [maxPagesPerSearch] pages.
Future<SearchResult> searchArea(http.Client client, String apiKey, SearchRect rect) async {
  final results = <GooglePlace>[];
  String? pageToken;
  var requests = 0;
  for (var page = 0; page < maxPagesPerSearch; page++) {
    requests++;
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
            'low': {'latitude': rect.minLat, 'longitude': rect.minLon},
            'high': {'latitude': rect.maxLat, 'longitude': rect.maxLon},
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
  return (places: results, full: pageToken != null, requests: requests);
}

/// Searches the quarters of [rect], whose own search came back full, and
/// splits full quarters again, [splits] levels deep. [maySplit] is asked
/// before each split for its four searches. False if it refused one, so
/// places may be missing.
Future<bool> searchQuarters(
  http.Client client,
  String apiKey,
  SearchRect rect, {
  required int splits,
  required Future<bool> Function() maySplit,
  required Future<void> Function(SearchResult result) found,
}) async {
  if (splits == 0) return true;
  if (!await maySplit()) return false;
  // In parallel, so the map doesn't wait for one search after the other.
  final complete = await Future.wait(rect.quarters.map((quarter) async {
    final result = await searchArea(client, apiKey, quarter);
    await found(result);
    return !result.full || await searchQuarters(client, apiKey, quarter, splits: splits - 1, maySplit: maySplit, found: found);
  }));
  return !complete.contains(false);
}
