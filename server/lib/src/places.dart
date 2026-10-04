import 'dart:math' as math;

import 'package:doener_models/doener_models.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'deps.dart';
import 'google_places.dart';
import 'http.dart';

const liveStatusDuration = Duration(hours: 1);
const _maxSyncSpanDeg = 0.5;

/// "Im Umkreis": community reviews, top places and trends count within this distance.
const communityRadius = 10000.0;

/// How long a place counts as new after it opened.
const newPlaceDays = 30;

PlaceDto placeFromRow(Map<String, dynamic> row) => PlaceDto(
      placeId: row['google_place_id'] as String,
      name: row['name'] as String,
      latitude: row['latitude'] as double,
      longitude: row['longitude'] as double,
      address: row['address'] as String?,
      postalCode: row['postal_code'] as String?,
      city: row['city'] as String?,
      openingHours: row['opening_hours'] as String?,
      avgRating: row['avg_rating'] as double?,
      reviewCount: row['review_count'] as int,
      avgVegetarian: row['avg_vegetarian'] as double?,
      vegetarianCount: row['vegetarian_count'] as int,
      avgVegan: row['avg_vegan'] as double?,
      veganCount: row['vegan_count'] as int,
      veganOptions: row['vegan_options'] as bool?,
      openedOn: row['opened_on'] as DateTime?,
      opensOn: row['opening_date'] as String?,
    );

/// Sauce, meat and bread come from their columns, everything else from
/// `items` (the review's review_items as JSON, see [reviewItemsJson]).
Map<RatingItem, int> ratingsFromRow(Map<String, dynamic> row) => {
      RatingItem.sauce: ?row['sauce_rating'] as int?,
      RatingItem.fleisch: ?row['fleisch_rating'] as int?,
      RatingItem.brot: ?row['brot_rating'] as int?,
      for (final e in ((row['items'] as Map?) ?? const {}).entries) RatingItem.values.byName(e.key as String): e.value as int,
    };

/// Select expression for the items of review `r`.
const reviewItemsJson = '(SELECT jsonb_object_agg(item, rating) FROM review_items WHERE review_id = r.id) AS items';

ReviewDto reviewFromRow(Map<String, dynamic> row) => ReviewDto(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      userName: row['display_name'] as String,
      placeId: row['google_place_id'] as String,
      placeName: row['place_name'] as String,
      rating: row['rating'] as int?,
      ratings: ratingsFromRow(row),
      veganOptions: row['vegan_options'] as bool?,
      ayranHomemade: row['ayran_homemade'] as bool?,
      ingredients: (row['ingredients'] as List?)?.map((i) => Ingredient.values.byName(i as String)).toList(),
      meat: Meat.values.asNameMap()[row['meat']],
      skewer: Skewer.values.asNameMap()[row['skewer']],
      bread: Bread.values.asNameMap()[row['bread']],
      text: row['text'] as String?,
      createdAt: row['created_at'] as DateTime,
      updatedAt: row['updated_at'] as DateTime,
    );

VisitDto visitFromRow(Map<String, dynamic> row) => VisitDto(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      userName: row['display_name'] as String,
      placeId: row['google_place_id'] as String,
      placeName: row['place_name'] as String,
      visitedAt: row['visited_at'] as DateTime,
      foodType: row['food_type'] as String?,
    );

const _reviewSelect = 'SELECT r.*, $reviewItemsJson, u.display_name, p.google_place_id, p.name AS place_name '
    'FROM reviews r JOIN users u ON u.id = r.user_id JOIN places p ON p.id = r.place_id';
const _visitSelect = 'SELECT v.*, u.display_name, p.google_place_id, p.name AS place_name FROM visits v '
    'JOIN users u ON u.id = v.user_id JOIN places p ON p.id = v.place_id';

Future<Map<String, dynamic>> _requirePlace(Deps deps, String placeId) async {
  final row = await queryOne(deps.db, 'SELECT * FROM place_view WHERE google_place_id = @id', {'id': placeId});
  if (row == null) throw const ApiException.notFound('Laden unbekannt');
  return row;
}

void mountPlaces(Router router, Deps deps) {
  // GET /places?minLat&minLon&maxLat&maxLon — places in the visible map area.
  router.get('/places', (Request request) async {
    final user = await requireUser(deps, request);
    final minLat = queryDouble(request, 'minLat');
    final minLon = queryDouble(request, 'minLon');
    final maxLat = queryDouble(request, 'maxLat');
    final maxLon = queryDouble(request, 'maxLon');
    if (minLat >= maxLat || minLon >= maxLon || minLat < -90 || maxLat > 90 || minLon < -180 || maxLon > 180) {
      throw const ApiException.badRequest('Ungültiger Kartenausschnitt');
    }

    final apiKey = deps.config.googlePlacesApiKey;
    if (apiKey != null && maxLat - minLat <= _maxSyncSpanDeg && maxLon - minLon <= _maxSyncSpanDeg) {
      final tiles = tilesCovering(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon);
      if (tiles.length <= maxTilesPerRequest) await Future.wait(tiles.map((t) => _syncTile(deps, apiKey, t, user.id)));
    }

    final rows = await query(
      deps.db,
      'SELECT * FROM place_view WHERE latitude BETWEEN @minLat AND @maxLat AND longitude BETWEEN @minLon AND @maxLon '
      'ORDER BY review_count DESC, name LIMIT 300',
      {'minLat': minLat, 'maxLat': maxLat, 'minLon': minLon, 'maxLon': maxLon},
    );
    return json(rows.map((r) => placeFromRow(r).toJson()).toList());
  });

  // GET /places/top?lat&lon[&by] — best around by weighted rating, for the
  // Döner (`overall`) or the main score of `vegetarian` or `vegan`. Where too
  // few places are rated, the nearest unrated ones fill up the list.
  router.get('/places/top', (Request request) async {
    final lat = queryDouble(request, 'lat');
    final lon = queryDouble(request, 'lon');
    final radius = queryDouble(request, 'radius', fallback: communityRadius).clamp(100, 20000).toDouble();
    final limit = queryInt(request, 'limit', fallback: 10, min: 1, max: 50);
    final diet = RankBy.parse(request.url.queryParameters['by'] ?? RankBy.overall.key)?.diet;
    if (diet == null) throw const ApiException.badRequest('Parameter "by" ist ungültig');
    final (avg, count) = _scoreColumns[diet]!;
    final area = radiusParams(lat, lon, radius);
    // Vegans don't need places where most people found nothing vegan, rated or not.
    final veganFilter = diet == Diet.vegan ? 'AND p.vegan_options IS NOT false ' : '';

    final rated = rankByWeight(await query(
      deps.db,
      'SELECT p.*, p.$avg AS avg, p.$count AS n FROM place_view p '
      'WHERE p.$count > 0 ${veganFilter}AND ${withinRadius('p')}',
      area,
    )).take(limit).toList();
    final unrated = rated.length == limit
        ? const <Map<String, dynamic>>[]
        : await query(
            deps.db,
            'SELECT * FROM place_view p WHERE p.$count = 0 $veganFilter'
            'AND ${withinRadius('p')} ORDER BY ${distanceSql('p')} LIMIT @rest:int4',
            {...area, 'rest': limit - rated.length},
          );
    return json([...rated, ...unrated].map((r) => placeFromRow(r).toJson()).toList());
  });

  // GET /places/new?lat&lon — around: places that opened lately and the
  // openings Google announced.
  router.get('/places/new', (Request request) async {
    final area = radiusParams(queryDouble(request, 'lat'), queryDouble(request, 'lon'), communityRadius);
    final opened = await query(
      deps.db,
      'SELECT * FROM place_view p WHERE p.opened_on > current_date - @days:int4 AND ${withinRadius('p')} '
      'ORDER BY p.opened_on DESC, p.name',
      {...area, 'days': newPlaceDays},
    );
    final upcoming = await query(
      deps.db,
      'SELECT p.*, NULL::float8 AS avg_rating, 0 AS review_count, NULL::float8 AS avg_vegetarian, 0 AS vegetarian_count, '
      'NULL::float8 AS avg_vegan, 0 AS vegan_count, NULL::boolean AS vegan_options FROM places p '
      "WHERE p.business_status = 'FUTURE_OPENING' AND ${withinRadius('p')} ORDER BY p.opening_date NULLS LAST, p.name",
      area,
    );
    return json(NewPlacesDto(opened: opened.map(placeFromRow).toList(), upcoming: upcoming.map(placeFromRow).toList()).toJson());
  });

  // GET /places/trending?lat&lon — most check-ins and reviews around in the
  // last days. Check-ins count without saying whose.
  router.get('/places/trending', (Request request) async {
    final area = radiusParams(queryDouble(request, 'lat'), queryDouble(request, 'lon'), communityRadius);
    final days = queryInt(request, 'days', fallback: 7, min: 1, max: 30);
    final limit = queryInt(request, 'limit', fallback: 10, min: 1, max: 50);
    final rows = await query(
      deps.db,
      'SELECT pv.* FROM ('
      '  SELECT x.place_id, count(*) AS activity FROM ('
      '    SELECT place_id FROM reviews WHERE updated_at > now() - make_interval(days => @days:int4)'
      '    UNION ALL'
      '    SELECT place_id FROM visits WHERE visited_at > now() - make_interval(days => @days:int4)'
      '  ) x JOIN places p ON p.id = x.place_id WHERE ${withinRadius('p')}'
      '  GROUP BY x.place_id ORDER BY activity DESC LIMIT @limit:int4'
      ') a JOIN place_view pv ON pv.id = a.place_id ORDER BY a.activity DESC, pv.name',
      {...area, 'days': days, 'limit': limit},
    );
    return json(rows.map((r) => placeFromRow(r).toJson()).toList());
  });

  router.get('/places/<placeId>', (Request request, String placeId) async {
    return json(placeFromRow(await _requirePlace(deps, placeId)).toJson());
  });

  router.get('/places/<placeId>/reviews', (Request request, String placeId) async {
    final rows = await query(
      deps.db,
      '$_reviewSelect WHERE p.google_place_id = @id ORDER BY r.updated_at DESC LIMIT 100',
      {'id': placeId},
    );
    return json(rows.map((r) => reviewFromRow(r).toJson()).toList());
  });

  router.get('/places/<placeId>/summary', (Request request, String placeId) async {
    final rows = await query(
      deps.db,
      'SELECT r.*, $reviewItemsJson FROM reviews r JOIN places p ON p.id = r.place_id WHERE p.google_place_id = @id',
      {'id': placeId},
    );
    return json(summarize(rows).toJson());
  });

  router.put('/places/<placeId>/review', (Request request, String placeId) async {
    final user = await requireUser(deps, request);
    final body = await readBody(request, UpsertReviewRequest.fromJson);
    final ratings = body.ratings;
    if (!ratings.values.every(Validation.isValidRating)) throw const ApiException.badRequest('Bewertungen müssen 1–5 sein');
    final text = Validation.clean(body.text);
    if ((text?.length ?? 0) > Validation.reviewTextMax) throw const ApiException.badRequest('Text zu lang');

    // Whoever rates vegan food or ayran says the place has it.
    final veganRated = RatingItem.veganItems.any(ratings.containsKey);
    if (veganRated && body.veganOptions == false) {
      throw const ApiException.badRequest('Vegane Optionen bewertet, aber keine angegeben');
    }
    final ayranRated = ratings.containsKey(RatingItem.ayran);
    if (ayranRated && body.ayranHomemade == false) {
      throw const ApiException.badRequest('Bewertet wird nur selbstgemachter Ayran');
    }
    final veganOptions = veganRated ? true : body.veganOptions;
    final ayranHomemade = ayranRated ? true : body.ayranHomemade;
    if (ratings.isEmpty &&
        veganOptions == null &&
        ayranHomemade == null &&
        body.ingredients == null &&
        body.meat == null &&
        body.skewer == null &&
        body.bread == null &&
        text == null) {
      throw const ApiException.badRequest('Die Bewertung ist leer');
    }
    final place = await _requirePlace(deps, placeId);

    final items = {for (final e in ratings.entries) if (!e.key.isDoener) e.key.name: e.value};
    final saved = await deps.db.runTx((tx) async {
      final row = await queryOne(
        tx,
        'INSERT INTO reviews (user_id, place_id, rating, vegetarian_rating, vegan_rating, sauce_rating, fleisch_rating, '
        'brot_rating, vegan_options, ayran_homemade, ingredients, meat, skewer, bread, text) '
        'VALUES (@user:uuid, @place:uuid, @rating:int4, @vegetarian:int4, @vegan:int4, @sauce:int4, @fleisch:int4, '
        '@brot:int4, @veganOptions:boolean, @ayran:boolean, @ingredients:_text, @meat:text, @skewer:text, @bread:text, @text) '
        // Older reviews may only have an overall rating, without sauce, meat or
        // bread. It stays until the review rates the Döner itself.
        'ON CONFLICT (user_id, place_id) DO UPDATE SET rating = CASE WHEN num_nonnulls(EXCLUDED.sauce_rating, '
        'EXCLUDED.fleisch_rating, EXCLUDED.brot_rating, reviews.sauce_rating, reviews.fleisch_rating, reviews.brot_rating) = 0 '
        'THEN reviews.rating ELSE EXCLUDED.rating END, '
        'vegetarian_rating = EXCLUDED.vegetarian_rating, vegan_rating = EXCLUDED.vegan_rating, '
        'sauce_rating = EXCLUDED.sauce_rating, fleisch_rating = EXCLUDED.fleisch_rating, brot_rating = EXCLUDED.brot_rating, '
        'vegan_options = EXCLUDED.vegan_options, ayran_homemade = EXCLUDED.ayran_homemade, '
        'ingredients = EXCLUDED.ingredients, meat = EXCLUDED.meat, skewer = EXCLUDED.skewer, bread = EXCLUDED.bread, '
        'text = EXCLUDED.text, updated_at = now() RETURNING *',
        {
          'user': user.id,
          'place': place['id'],
          'rating': Diet.all.score(ratings)?.round(),
          'vegetarian': Diet.vegetarian.score(ratings)?.round(),
          // Whoever found nothing vegan rated no vegan food, a falafel included.
          'vegan': veganOptions == false ? null : Diet.vegan.score(ratings)?.round(),
          'sauce': ratings[RatingItem.sauce],
          'fleisch': ratings[RatingItem.fleisch],
          'brot': ratings[RatingItem.brot],
          'veganOptions': veganOptions,
          'ayran': ayranHomemade,
          'ingredients': body.ingredients?.map((i) => i.name).toList(),
          'meat': body.meat?.name,
          'skewer': body.skewer?.name,
          'bread': body.bread?.name,
          'text': text,
        },
      );
      await tx.execute(Sql.named('DELETE FROM review_items WHERE review_id = @id:uuid'), parameters: {'id': row!['id']});
      for (final e in items.entries) {
        await tx.execute(
          Sql.named('INSERT INTO review_items (review_id, item, rating) VALUES (@id:uuid, @item, @rating:int4)'),
          parameters: {'id': row['id'], 'item': e.key, 'rating': e.value},
        );
      }
      return row;
    });
    return json(reviewFromRow({
      ...saved,
      'items': items,
      'display_name': user.displayName,
      'google_place_id': placeId,
      'place_name': place['name'],
    }).toJson());
  });

  router.post('/places/<placeId>/visits', (Request request, String placeId) async {
    final user = await requireUser(deps, request);
    final body = await readBody(request, CreateVisitRequest.fromJson);
    final id = requireUuid(body.id);
    final now = DateTime.now().toUtc();
    if (body.visitedAt.isAfter(now.add(const Duration(minutes: 5)))) {
      throw const ApiException.badRequest('Besuch liegt in der Zukunft');
    }
    if (body.foodType != null && FoodItem.byId(body.foodType) == null) {
      throw const ApiException.badRequest('Unbekannter Essenstyp');
    }
    final place = await _requirePlace(deps, placeId);

    // Client-generated IDs make offline retries idempotent.
    final inserted = await queryOne(
      deps.db,
      'INSERT INTO visits (id, user_id, place_id, visited_at, food_type) '
      'VALUES (@id:uuid, @user:uuid, @place:uuid, @at:timestamptz, @food) '
      'ON CONFLICT (id) DO NOTHING RETURNING id',
      {'id': id, 'user': user.id, 'place': place['id'], 'at': body.visitedAt, 'food': body.foodType},
    );
    if (inserted == null) {
      final existing = await queryOne(deps.db, '$_visitSelect WHERE v.id = @id:uuid', {'id': id});
      if (existing == null || existing['user_id'] != user.id) throw const ApiException.conflict('Besuchs-ID vergeben');
      return json(visitFromRow(existing).toJson());
    }

    // Only a visit that is actually happening now counts as "live" — not
    // one synced hours later from the offline queue.
    final liveUntil = body.visitedAt.toUtc().add(liveStatusDuration);
    if (liveUntil.isAfter(now)) {
      await deps.db.execute(
        Sql.named('UPDATE users SET live_place_id = @place:uuid, live_until = @until:timestamptz, live_food_type = @food '
            'WHERE id = @user:uuid'),
        parameters: {'place': place['id'], 'until': liveUntil, 'food': body.foodType, 'user': user.id},
      );
    }

    final row = await queryOne(deps.db, '$_visitSelect WHERE v.id = @id:uuid', {'id': id});
    return json(visitFromRow(row!).toJson(), status: 201);
  });

  router.get('/me/visits', (Request request) async {
    final user = await requireUser(deps, request);
    final rows = await query(deps.db, '$_visitSelect WHERE v.user_id = @user:uuid ORDER BY v.visited_at DESC', {
      'user': user.id,
    });
    return json(rows.map((r) => visitFromRow(r).toJson()).toList());
  });

  router.get('/me/reviews', (Request request) async {
    final user = await requireUser(deps, request);
    final rows = await query(deps.db, '$_reviewSelect WHERE r.user_id = @user:uuid ORDER BY r.updated_at DESC', {
      'user': user.id,
    });
    return json(rows.map((r) => reviewFromRow(r).toJson()).toList());
  });

  // Places of the user's own visits/reviews — lets a fresh device (or the
  // web app) show history without panning the map first.
  router.get('/me/places', (Request request) async {
    final user = await requireUser(deps, request);
    final rows = await query(
      deps.db,
      'SELECT * FROM place_view WHERE id IN (SELECT place_id FROM visits WHERE user_id = @user:uuid '
      'UNION SELECT place_id FROM reviews WHERE user_id = @user:uuid)',
      {'user': user.id},
    );
    return json(rows.map((r) => placeFromRow(r).toJson()).toList());
  });
}

Future<void> _syncTile(Deps deps, String apiKey, Tile tile, String userId) async {
  // Atomically claim the tile so concurrent requests don't both pay Google.
  final claimed = await queryOne(
    deps.db,
    'INSERT INTO search_tiles (tile_key, searched_at) VALUES (@key, now()) '
    'ON CONFLICT (tile_key) DO UPDATE SET searched_at = now() '
    'WHERE search_tiles.searched_at < now() - make_interval(days => @ttl:int4) RETURNING tile_key',
    {'key': tile.key, 'ttl': tileTtl.inDays},
  );
  if (claimed == null) return;

  // Counted atomically as well — parallel tiles and requests can't overshoot the limit.
  final counted = await queryOne(
    deps.db,
    'INSERT INTO daily_searches (user_id, day, count) VALUES (@user:uuid, current_date, 1) '
    'ON CONFLICT (user_id, day) DO UPDATE SET count = daily_searches.count + 1 '
    'WHERE daily_searches.count < @max:int4 RETURNING count',
    {'user': userId, 'max': maxTileSearchesPerDay},
  );
  if (counted == null) {
    // Limit reached: hand the tile back for the next user.
    await deps.db.execute(Sql.named('DELETE FROM search_tiles WHERE tile_key = @key'), parameters: {'key': tile.key});
    return;
  }

  try {
    final places = await searchTile(deps.httpClient, apiKey, tile);
    for (final p in places.where((p) => p.isOpenBusiness && p.looksLikeDoener)) {
      await _upsertPlace(deps, p);
    }
  } catch (e) {
    print('Tile ${tile.key} sync failed: $e');
    await deps.db.execute(Sql.named('DELETE FROM search_tiles WHERE tile_key = @key'), parameters: {'key': tile.key});
  }
}

Future<void> _upsertPlace(Deps deps, GooglePlace p) => deps.db.execute(
      Sql.named(
        'INSERT INTO places (google_place_id, name, latitude, longitude, address, postal_code, city, opening_hours, '
        'business_status, opening_date) VALUES (@id, @name, @lat, @lon, @address, @postal, @city, @hours, @status, @opening) '
        'ON CONFLICT (google_place_id) DO UPDATE SET name = EXCLUDED.name, latitude = EXCLUDED.latitude, '
        'longitude = EXCLUDED.longitude, address = EXCLUDED.address, postal_code = EXCLUDED.postal_code, '
        'city = EXCLUDED.city, opening_hours = EXCLUDED.opening_hours, business_status = EXCLUDED.business_status, '
        'opening_date = EXCLUDED.opening_date, synced_at = now(), '
        // An announced shop that is open now — that's the news.
        "opened_on = CASE WHEN places.business_status = 'FUTURE_OPENING' AND EXCLUDED.business_status = 'OPERATIONAL' "
        'THEN current_date ELSE places.opened_on END',
      ),
      parameters: {
        'id': p.id,
        'name': p.name,
        'lat': p.latitude,
        'lon': p.longitude,
        'address': p.address,
        'postal': p.postalCode,
        'city': p.city,
        'hours': p.openingHours,
        'status': p.businessStatus,
        'opening': p.openingDate,
      },
    );

/// Keeps the place cache within Google's terms: details may be stored for at
/// most 30 days (only the place ID indefinitely). Places with user activity
/// are refreshed before that; untouched ones are dropped and come back when
/// someone looks at the area again. Runs daily.
Future<void> maintainPlaceCache(Deps deps) async {
  const activity = 'EXISTS (SELECT 1 FROM reviews r WHERE r.place_id = p.id) '
      'OR EXISTS (SELECT 1 FROM visits v WHERE v.place_id = p.id) '
      'OR EXISTS (SELECT 1 FROM users u WHERE u.live_place_id = p.id) '
      // Announced openings stay until they open.
      "OR p.business_status IS NOT DISTINCT FROM 'FUTURE_OPENING'";

  final apiKey = deps.config.googlePlacesApiKey;
  if (apiKey != null) {
    final stale = await query(
      deps.db,
      "SELECT google_place_id FROM places p WHERE (synced_at < now() - interval '25 days' AND ($activity)) "
      // From the announced day on (daily without one): has it opened?
      "OR (business_status = 'FUTURE_OPENING' AND (opening_date IS NULL OR opening_date <= to_char(current_date, 'YYYY-MM-DD')))",
    );
    for (final row in stale) {
      final id = row['google_place_id'] as String;
      try {
        final place = await fetchPlace(deps.httpClient, apiKey, id);
        if (place != null) {
          await _upsertPlace(deps, place);
        } else {
          // An announcement Google withdrew.
          await deps.db.execute(
            Sql.named("DELETE FROM places WHERE google_place_id = @id AND business_status = 'FUTURE_OPENING'"),
            parameters: {'id': id},
          );
        }
      } catch (e) {
        print('Refreshing place $id failed: $e');
      }
    }
  }

  final deleted = await query(
    deps.db,
    "DELETE FROM places p WHERE synced_at < now() - interval '30 days' AND NOT ($activity) RETURNING id",
  );
  if (deleted.isNotEmpty) print('Place cache: dropped ${deleted.length} places older than 30 days');
}

(double, double) _degreeDeltas(double lat, double radiusMeters) {
  const metersPerDegree = 111000.0;
  final cosLat = math.cos(lat * math.pi / 180).abs().clamp(0.01, 1.0);
  return (radiusMeters / metersPerDegree, radiusMeters / (metersPerDegree * cosLat));
}

/// Parameters for [withinRadius] and [distanceSql].
Map<String, Object> radiusParams(double lat, double lon, double radiusMeters) {
  final (latDelta, lonDelta) = _degreeDeltas(lat, radiusMeters);
  return {
    'lat': lat,
    'lon': lon,
    'radius': radiusMeters,
    'minLat': lat - latDelta,
    'maxLat': lat + latDelta,
    'minLon': lon - lonDelta,
    'maxLon': lon + lonDelta,
  };
}

/// SQL condition: place [alias] lies within @radius meters of @lat/@lon. The
/// bounding box comes first so Postgres can use the coordinate index.
String withinRadius(String alias) =>
    '$alias.latitude BETWEEN @minLat AND @maxLat AND $alias.longitude BETWEEN @minLon AND @maxLon '
    'AND ${distanceSql(alias)} <= @radius';

/// Meters from @lat/@lon — a flat-earth approximation, exact enough within a city.
String distanceSql(String alias) =>
    '111195 * sqrt(power($alias.latitude - @lat, 2) + power(($alias.longitude - @lon) * cos(radians(@lat)), 2))';

/// Best first by [weightedRating]; rows need `avg` and `n` (review count).
/// The mean is that of all reviews in [rows] — the area or city being ranked.
List<Map<String, dynamic>> rankByWeight(List<Map<String, dynamic>> rows) {
  var total = 0.0;
  var count = 0;
  for (final r in rows) {
    total += (r['avg'] as double) * (r['n'] as int);
    count += r['n'] as int;
  }
  final score = {for (final r in rows) r['id']: weightedRating(r['avg'] as double, r['n'] as int, total / count)};

  int compare(Map<String, dynamic> a, Map<String, dynamic> b) {
    final byScore = score[b['id']]!.compareTo(score[a['id']]!);
    if (byScore != 0) return byScore;
    final byCount = (b['n'] as int).compareTo(a['n'] as int);
    return byCount != 0 ? byCount : (a['name'] as String).compareTo(b['name'] as String);
  }

  return [...rows]..sort(compare);
}

const _scoreColumns = {
  Diet.all: ('avg_rating', 'review_count'),
  Diet.vegetarian: ('avg_vegetarian', 'vegetarian_count'),
  Diet.vegan: ('avg_vegan', 'vegan_count'),
};

/// What the community says about a place, from its review rows.
PlaceSummaryDto summarize(List<Map<String, dynamic>> reviews) {
  final values = <RatingItem, List<int>>{};
  for (final review in reviews) {
    for (final e in ratingsFromRow(review).entries) {
      (values[e.key] ??= []).add(e.value);
    }
  }
  final experts = [for (final r in reviews) if (r['ingredients'] case final List list) list];
  return PlaceSummaryDto(
    items: {
      for (final item in RatingItem.values)
        if (values[item] case final v?) item: ItemAverage(v.reduce((a, b) => a + b) / v.length, v.length),
    },
    ayranHomemade: plurality([for (final r in reviews) r['ayran_homemade'] as bool?]),
    // What at least half of the experts got.
    ingredients: [
      for (final i in Ingredient.values)
        if (experts.isNotEmpty && experts.where((list) => list.contains(i.name)).length * 2 >= experts.length) i,
    ],
    meat: Meat.values.asNameMap()[plurality([for (final r in reviews) r['meat'] as String?])],
    skewer: Skewer.values.asNameMap()[plurality([for (final r in reviews) r['skewer'] as String?])],
    bread: Bread.values.asNameMap()[plurality([for (final r in reviews) r['bread'] as String?])],
    experts: experts.length,
  );
}

/// The most common answer — null if nobody answered or it's a tie.
T? plurality<T extends Object>(Iterable<T?> answers) {
  final counts = <T, int>{};
  for (final answer in answers.nonNulls) {
    counts[answer] = (counts[answer] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  final most = counts.values.reduce(math.max);
  final top = [for (final e in counts.entries) if (e.value == most) e.key];
  return top.length == 1 ? top.single : null;
}
