import 'package:doener_models/doener_models.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'deps.dart';
import 'http.dart';
import 'moderation.dart';
import 'ranking.dart';
import 'social.dart';

/// The bell on Start: what happened lately, so nobody depends on a push to
/// catch up. Built from the activity itself, not from the pushes, so it also
/// works without push and shows what the quiet hours held back.
void mountInbox(Router router, Deps deps) {
  // GET /me/inbox[?lat&lon] — the last 7 days, newest first, at most 50; open
  // friend requests regardless of their age. New shops are those of the city
  // at the position, else of the city the push token reported. `seenAt` is
  // when the bell was last opened on any device, `loadedAt` the server's time
  // of this answer, which the app sends back as seen.
  router.get('/me/inbox', (Request request) async {
    final me = await requireUser(deps, request);
    final here = request.url.queryParameters.containsKey('lat')
        ? await nearestCity(deps.db, queryDouble(request, 'lat'), queryDouble(request, 'lon'))
        : null;
    final user = await queryOne(deps.db, 'SELECT inbox_seen_at, city, now() AS now FROM users WHERE id = @me:uuid', {'me': me.id});
    final rows = await query(
      deps.db,
      '$friendIdsCte SELECT i.*, a.display_name AS actor_name, p.name AS place_name, p.google_place_id, p.city AS place_city FROM ('
      "  SELECT 'friend_visit' AS type, v.id::text AS id, v.visited_at AS ts, v.user_id AS actor_id, v.place_id,"
      '         NULL::text AS emoji, NULL::text AS extra'
      "  FROM visits v WHERE v.user_id IN (SELECT id FROM friends) AND v.visited_at > now() - interval '7 days'"
      '  UNION ALL'
      "  SELECT 'friend_review', r.id::text, r.updated_at, r.user_id, r.place_id, NULL, NULL"
      "  FROM reviews r WHERE r.user_id IN (SELECT id FROM friends) AND r.updated_at > now() - interval '7 days'"
      '  UNION ALL'
      "  SELECT 'reaction', x.user_id::text || coalesce(x.visit_id, x.review_id)::text, x.created_at, x.user_id,"
      "         coalesce(v.place_id, r.place_id), x.emoji, CASE WHEN x.visit_id IS NULL THEN 'review' ELSE 'visit' END"
      '  FROM reactions x LEFT JOIN visits v ON v.id = x.visit_id LEFT JOIN reviews r ON r.id = x.review_id'
      "  WHERE @me:uuid IN (v.user_id, r.user_id) AND x.user_id <> @me:uuid AND x.created_at > now() - interval '7 days'"
      '  UNION ALL'
      "  SELECT 'friend_request', f.id::text, f.created_at, f.requester_id, NULL, NULL, NULL"
      "  FROM friendships f WHERE f.addressee_id = @me:uuid AND f.status = 'pending'"
      '  UNION ALL'
      "  SELECT 'new_place', p.id::text, coalesce(p.opening_pushed_at, p.opened_on::timestamptz), NULL, p.id, NULL, NULL"
      '  FROM places p'
      "  WHERE p.city = @city:text AND p.opened_on > current_date - 7 AND p.opened_on <= current_date AND p.business_status IS DISTINCT FROM 'CLOSED_PERMANENTLY'"
      '  UNION ALL'
      "  SELECT 'news', n.id::text, n.published_at, NULL, NULL, NULL, n.title"
      "  FROM updates n WHERE n.in_app AND n.published_at > now() - interval '7 days'"
      ') i LEFT JOIN users a ON a.id = i.actor_id LEFT JOIN places p ON p.id = i.place_id'
      ' WHERE i.actor_id IS NULL OR ${notBlocked('i.actor_id')}'
      ' ORDER BY i.ts DESC, i.id LIMIT 50',
      {'me': me.id, 'city': here ?? user!['city']},
    );
    return json(InboxDto(
      items: [for (final r in rows) _item(r)],
      seenAt: user!['inbox_seen_at'] as DateTime?,
      loadedAt: user['now'] as DateTime,
    ).toJson());
  });

  // POST /me/inbox/seen[?until=<loadedAt>] — the bell was opened: everything
  // up to the time it was loaded is seen, on all devices, not what came in
  // since. Shops held back by the quiet hours then don't push any more.
  router.post('/me/inbox/seen', (Request request) async {
    final me = await requireUser(deps, request);
    final until = request.url.queryParameters['until'];
    final at = until == null ? null : DateTime.tryParse(until);
    if (until != null && at == null) throw const ApiException.badRequest('Ungültige Zeit');
    await deps.db.execute(
      Sql.named('UPDATE users SET inbox_seen_at = greatest(inbox_seen_at, least(coalesce(@at:timestamptz, now()), now())) '
          'WHERE id = @me:uuid'),
      parameters: {'me': me.id, 'at': at},
    );
    return noContent();
  });
}

InboxItemDto _item(Map<String, dynamic> r) {
  final type = r['type'] as String;
  final actor = r['actor_name'] as String?;
  final place = r['place_name'] as String?;
  return InboxItemDto(
    type: type,
    id: r['id'] as String,
    timestamp: r['ts'] as DateTime,
    title: switch (type) {
      'friend_visit' => '$actor hat bei $place eingecheckt',
      'friend_review' => '$actor hat $place bewertet',
      'reaction' => '$actor reagiert ${r['emoji']} auf ${r['extra'] == 'visit' ? 'deinen Check-in bei' : 'deine Bewertung von'} $place',
      'friend_request' => '$actor möchte mit dir befreundet sein',
      'new_place' => 'Neuer Döner in ${r['place_city']}',
      _ => 'Neu in der Döner App',
    },
    body: switch (type) {
      'new_place' => '$place hat aufgemacht',
      'news' => r['extra'] as String?,
      _ => null,
    },
    placeId: r['google_place_id'] as String?,
    userId: r['actor_id'] as String?,
    userName: actor,
  );
}
