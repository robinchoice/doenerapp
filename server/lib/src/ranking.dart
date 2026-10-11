import 'package:doener_models/doener_models.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
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

void mountRanking(Router router, Deps deps) {
  // GET /ranking?lat&lon&by — the rated places of the city around lat/lon
  // (by their address), best first, with the friends who rated them.
  router.get('/ranking', (Request request) async {
    final me = await requireUser(deps, request);
    final lat = queryDouble(request, 'lat');
    final lon = queryDouble(request, 'lon');
    final by = RankBy.parse(request.url.queryParameters['by'] ?? RankBy.overall.key);
    if (by == null) throw const ApiException.badRequest('Parameter "by" ist ungültig');
    final ratings = _ratings(by);
    final itemParam = {if (by.item case final item? when !item.isDoener) 'item': item.name};

    final nearest = await queryOne(
      deps.db,
      'SELECT city FROM places p WHERE city IS NOT NULL AND ${withinRadius('p')} ORDER BY ${distanceSql('p')} LIMIT 1',
      radiusParams(lat, lon, _cityRadius),
    );
    final city = nearest?['city'] as String?;
    if (city == null) return json(RankingDto(by: by, entries: const []).toJson());

    final rows = rankByWeight(await query(
      deps.db,
      'SELECT pv.*, s.avg, s.n FROM place_view pv JOIN ('
      '  SELECT place_id, avg(value)::float8 AS avg, count(*)::int AS n FROM ($ratings) x GROUP BY place_id'
      ') s ON s.place_id = pv.id WHERE pv.city = @city',
      {'city': city, ...itemParam},
    )).take(_maxEntries).toList();

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

    return json(RankingDto(city: city, by: by, entries: [
      for (final r in rows)
        RankingEntryDto(
          place: placeFromRow(r),
          average: r['avg'] as double,
          count: r['n'] as int,
          friends: friends[r['id']] ?? const [],
        ),
    ]).toJson());
  });
}
