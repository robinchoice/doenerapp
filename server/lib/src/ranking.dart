import 'package:doener_models/doener_models.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'best_of.dart';
import 'deps.dart';
import 'http.dart';
import 'places.dart';
import 'social.dart';

/// "Your" city is the one of the nearest known place within this distance.
const _cityRadius = 20000.0;
const _maxEntries = 100;

/// One row per rating of [by] (place_id, user_id, value): the main scores and
/// the Döner items are review columns, everything else is in review_items.
String _ratings(RankBy by) {
  final column = switch (by) {
    RankBy(diet: Diet.all) => 'rating',
    RankBy(diet: Diet.vegetarian) => 'vegetarian_rating',
    RankBy(diet: Diet.vegan) => 'vegan_rating',
    RankBy(item: RatingItem.sauce) => 'sauce_rating',
    RankBy(item: RatingItem.fleisch) => 'fleisch_rating',
    RankBy(item: RatingItem.brot) => 'brot_rating',
    _ => null,
  };
  return column == null
      ? 'SELECT r.place_id, r.user_id, i.rating AS value FROM review_items i '
          'JOIN reviews r ON r.id = i.review_id WHERE i.item = @item'
      : 'SELECT place_id, user_id, $column AS value FROM reviews WHERE $column IS NOT NULL';
}

/// The city of the nearest known place within 20 km of [lat]/[lon] — "your" city.
Future<String?> nearestCity(Session db, double lat, double lon) async => (await queryOne(
      db,
      'SELECT city FROM places p WHERE city IS NOT NULL AND ${withinRadius('p')} ORDER BY ${distanceSql('p')} LIMIT 1',
      radiusParams(lat, lon, _cityRadius),
    ))?['city'] as String?;

/// Where [place] (a `places` row) stands in its city's Döner ranking, with the city.
Future<(int, String)?> cityRank(Session db, Map<String, dynamic> place) async {
  final city = place['city'] as String?;
  if (city == null) return null;
  final ranked = rankByWeight(await query(
    db,
    'SELECT pv.*, pv.avg_rating AS avg, pv.review_count AS n FROM active_place_view pv WHERE pv.city = @city AND pv.review_count > 0',
    {'city': city},
  ));
  final index = ranked.indexWhere((r) => r['id'] == place['id']);
  return index < 0 ? null : (index + 1, city);
}

void mountRanking(Router router, Deps deps) {
  // GET /ranking?lat&lon&by[&city][&maxPrice] — the rated places of the city
  // around lat/lon or of [city] (by their address), best first, with the
  // friends who rated them. With maxPrice (cents) only places whose Döner
  // mostly costs that much at most; they keep their order from the full list.
  router.get('/ranking', (Request request) async {
    final me = await requireUser(deps, request);
    final lat = queryDouble(request, 'lat');
    final lon = queryDouble(request, 'lon');
    final by = RankBy.parse(request.url.queryParameters['by'] ?? RankBy.overall.key);
    if (by == null) throw const ApiException.badRequest('Parameter "by" ist ungültig');
    final maxPriceParam = request.url.queryParameters['maxPrice'];
    final maxPrice = maxPriceParam == null ? null : int.tryParse(maxPriceParam);
    if (maxPriceParam != null && maxPrice == null) throw const ApiException.badRequest('Parameter "maxPrice" ist ungültig');
    final ratings = _ratings(by);
    final itemParam = {if (by.item case final item? when !RatingItem.classicItems.contains(item)) 'item': item.name};

    final city = request.url.queryParameters['city'] ?? await nearestCity(deps.db, lat, lon);
    if (city == null) return json(RankingDto(by: by, entries: const []).toJson());

    final rows = rankByWeight(await query(
      deps.db,
      'SELECT pv.*, s.avg, s.n, pr.price FROM active_place_view pv JOIN ('
      '  SELECT place_id, avg(value)::float8 AS avg, count(*)::int AS n FROM ($ratings) x GROUP BY place_id'
      ') s ON s.place_id = pv.id LEFT JOIN ('
      '  SELECT place_id, round(percentile_cont(0.5) WITHIN GROUP (ORDER BY price))::int AS price FROM reviews '
      '  WHERE price IS NOT NULL GROUP BY place_id'
      ') pr ON pr.place_id = pv.id WHERE pv.city = @city',
      {'city': city, ...itemParam},
    )).where((r) => maxPrice == null || (r['price'] is int && r['price'] as int <= maxPrice)).take(_maxEntries).toList();

    final friends = <String, List<FriendRatingDto>>{};
    if (rows.isNotEmpty) {
      final friendRows = await query(
        deps.db,
        '$friendIdsCte SELECT x.place_id, u.id, u.display_name, x.value FROM ($ratings) x '
        'JOIN users u ON u.id = x.user_id WHERE x.user_id IN (SELECT id FROM friends) '
        'AND x.place_id = ANY(@ids:_uuid) ORDER BY lower(u.display_name)',
        {'me': me.id, 'ids': [for (final r in rows) r['id'] as String], ...itemParam},
      );
      for (final f in friendRows) {
        friends.putIfAbsent(f['place_id'] as String, () => []).add(FriendRatingDto(
              user: UserDto(id: f['id'] as String, displayName: f['display_name'] as String),
              rating: f['value'] as double,
            ));
      }
    }

    final bestOf = await latestBestOf(deps.db, city, by.diet == Diet.vegan ? BestOfCategory.vegan : BestOfCategory.overall);
    return json(RankingDto(city: city, by: by, bestOf: bestOf, entries: [
      for (final r in rows)
        RankingEntryDto(
          place: placeFromRow(r),
          average: r['avg'] as double,
          count: r['n'] as int,
          friends: friends[r['id']] ?? const [],
          price: r['price'] as int?,
        ),
    ]).toJson());
  });

  // GET /cities — cities with rated places, most first, each with the middle
  // of its rated places, so anyone can look around there.
  router.get('/cities', (Request request) async {
    await requireUser(deps, request);
    final rows = await query(
      deps.db,
      'SELECT city, avg(latitude)::float8 AS lat, avg(longitude)::float8 AS lon, count(*)::int AS n FROM places '
      "WHERE business_status IS DISTINCT FROM 'CLOSED_PERMANENTLY' AND business_status IS DISTINCT FROM 'FUTURE_OPENING' "
      'AND city IS NOT NULL AND id IN (SELECT place_id FROM reviews) GROUP BY city ORDER BY n DESC, city LIMIT 50',
    );
    return json([
      for (final r in rows)
        CityDto(name: r['city'] as String, latitude: r['lat'] as double, longitude: r['lon'] as double, ratedPlaces: r['n'] as int)
            .toJson(),
    ]);
  });
}
