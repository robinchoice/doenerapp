import 'package:doener_models/doener_models.dart';
import 'package:postgres/postgres.dart';

import 'deps.dart';
import 'google_places.dart';
import 'push.dart';

/// False if the user's daily searches didn't suffice, so the tile stays open.
Future<bool> syncTile(Deps deps, String apiKey, Tile tile, String userId) async {
  // Atomically claim the tile so concurrent requests don't both pay Google.
  final claimed = await queryOne(
    deps.db,
    'INSERT INTO search_tiles (tile_key, searched_at) VALUES (@key, now()) '
    'ON CONFLICT (tile_key) DO UPDATE SET searched_at = now() '
    'WHERE search_tiles.searched_at < now() - make_interval(days => @ttl:int4) RETURNING tile_key',
    {'key': tile.key, 'ttl': tileTtl.inDays},
  );
  if (claimed == null) return true;
  // Hands the tile back for the next search.
  Future<void> release() => deps.db.execute(Sql.named('DELETE FROM search_tiles WHERE tile_key = @key'), parameters: {'key': tile.key});

  if (!await _countSearches(deps, userId, 1)) {
    await release();
    return false;
  }
  try {
    final rect = SearchRect.tile(tile);
    final result = await searchArea(deps.httpClient, apiKey, rect);
    await storeFoundPlaces(deps, result.places);
    // A full tile holds more shops than one search returns, so its quarters
    // are searched too, each search counted. Short of searches, the tile
    // stays open and is searched again in full later.
    if (result.full &&
        !await searchQuarters(deps.httpClient, apiKey, rect,
            splits: maxTileSplits,
            maySplit: () => _countSearches(deps, userId, 4),
            found: (r) => storeFoundPlaces(deps, r.places))) {
      await release();
      return false;
    }
  } catch (e) {
    print('Tile ${tile.key} sync failed: $e');
    await release();
  }
  return true;
}

/// Counts [n] Google searches for the user today, atomically, so parallel
/// tiles and requests can't overshoot the limit. False if they don't fit.
Future<bool> _countSearches(Deps deps, String userId, int n) async {
  final counted = await queryOne(
    deps.db,
    'INSERT INTO daily_searches (user_id, day, count) SELECT @user:uuid, current_date, @n:int4 WHERE @n:int4 <= @max:int4 '
    'ON CONFLICT (user_id, day) DO UPDATE SET count = daily_searches.count + @n:int4 '
    'WHERE daily_searches.count + @n:int4 <= @max:int4 RETURNING count',
    {'user': userId, 'n': n, 'max': maxTileSearchesPerDay},
  );
  return counted != null;
}

/// Loads one shop from Google into the cache; false if it is unknown, closed,
/// no Döner shop or the user's searches are used up.
Future<bool> fetchShop(Deps deps, String placeId, String userId) async {
  final apiKey = deps.config.googlePlacesApiKey;
  if (apiKey == null || !RegExp(r'^[A-Za-z0-9_-]{1,300}$').hasMatch(placeId)) return false;
  // Each lookup costs a Place Details call, so it counts like a search.
  if (!await _countSearches(deps, userId, 1)) return false;
  try {
    final place = await fetchPlace(deps.httpClient, apiKey, placeId);
    if (place == null || !place.isOpenBusiness || !place.looksLikeDoener) return false;
    await _upsertPlace(deps, place, withHours: true);
    return true;
  } catch (e) {
    print('Fetching place $placeId failed: $e');
    return false;
  }
}

/// Döner shops from a text search go into the cache, the rest is dropped.
Future<void> storeFoundPlaces(Deps deps, List<GooglePlace> places) async {
  for (final p in places.where((p) => p.isOpenBusiness && p.looksLikeDoener)) {
    await _upsertPlace(deps, p);
  }
}

/// Only Place Details bring opening hours ([withHours]); a text search keeps
/// the ones already known.
/// Closed and announced shops need no opening hours.
const _hoursDueSql = "coalesce(business_status, '') NOT IN ('CLOSED_PERMANENTLY', 'FUTURE_OPENING') "
    "AND (hours_synced_at IS NULL OR hours_synced_at < now() - interval '25 days')";

Future<bool> hoursDue(Deps deps, String placeId) async =>
    await queryOne(
      deps.db,
      'SELECT 1 FROM places WHERE google_place_id = @id AND $_hoursDueSql',
      {'id': placeId},
    ) !=
    null;

/// Opening hours of a known shop. Asked once per 25 days, even if Google has none.
Future<void> fetchHours(Deps deps, String apiKey, String placeId) async {
  try {
    final place = await fetchPlace(deps.httpClient, apiKey, placeId);
    if (place != null) {
      await _upsertPlace(deps, place, withHours: true);
    } else {
      await deps.db.execute(
        Sql.named('UPDATE places SET hours_synced_at = now() WHERE google_place_id = @id'),
        parameters: {'id': placeId},
      );
    }
  } catch (e) {
    print('Fetching opening hours of $placeId failed: $e');
  }
}

Future<void> _upsertPlace(Deps deps, GooglePlace p, {bool withHours = false}) => deps.db.execute(
      Sql.named(
        'INSERT INTO places (google_place_id, name, latitude, longitude, address, postal_code, city, opening_hours, '
        'hours_synced_at, business_status, opening_date) VALUES (@id, @name, @lat, @lon, @address, @postal, @city, @hours, '
        'CASE WHEN @withHours:boolean THEN now() END, @status, @opening) '
        'ON CONFLICT (google_place_id) DO UPDATE SET name = EXCLUDED.name, latitude = EXCLUDED.latitude, '
        'longitude = EXCLUDED.longitude, address = EXCLUDED.address, postal_code = EXCLUDED.postal_code, '
        'city = EXCLUDED.city, business_status = EXCLUDED.business_status, '
        'opening_hours = CASE WHEN @withHours:boolean THEN EXCLUDED.opening_hours ELSE places.opening_hours END, '
        'hours_synced_at = CASE WHEN @withHours:boolean THEN now() ELSE places.hours_synced_at END, '
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
        'withHours': withHours,
        'status': p.businessStatus,
        'opening': p.openingDate,
      },
    );

/// Keeps the place cache within Google's terms: details may be stored for at
/// most 30 days (only the place ID indefinitely). Places with user activity
/// are refreshed before that, with their opening hours; untouched ones are
/// dropped and come back when someone looks at the area again or the
/// prefetch searches it. Runs daily.
Future<void> maintainPlaceCache(Deps deps) async {
  const used = 'EXISTS (SELECT 1 FROM reviews r WHERE r.place_id = p.id) '
      'OR EXISTS (SELECT 1 FROM visits v WHERE v.place_id = p.id) '
      'OR EXISTS (SELECT 1 FROM users u WHERE u.live_place_id = p.id)';
  // Announced openings stay until they open.
  const activity = "$used OR p.business_status IS NOT DISTINCT FROM 'FUTURE_OPENING'";

  final apiKey = deps.config.googlePlacesApiKey;
  if (apiKey != null) {
    final stale = await query(
      deps.db,
      "SELECT google_place_id FROM places p WHERE (synced_at < now() - interval '25 days' AND ($activity)) "
      'OR (($used) AND $_hoursDueSql) '
      // From the announced day on (daily without one): has it opened?
      "OR (business_status = 'FUTURE_OPENING' AND (opening_date IS NULL OR opening_date <= to_char(current_date, 'YYYY-MM-DD')))",
    );
    for (final row in stale) {
      final id = row['google_place_id'] as String;
      try {
        final place = await fetchPlace(deps.httpClient, apiKey, id);
        if (place != null) {
          await _upsertPlace(deps, place, withHours: true);
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

  await deps.db.execute(
    "UPDATE places SET opening_hours = NULL WHERE opening_hours IS NOT NULL AND hours_synced_at < now() - interval '30 days'",
  );
  final deleted = await query(
    deps.db,
    "DELETE FROM places p WHERE synced_at < now() - interval '30 days' AND NOT ($activity) RETURNING id",
  );
  if (deleted.isNotEmpty) print('Place cache: dropped ${deleted.length} places older than 30 days');
  await pushOpenings(deps);
}
