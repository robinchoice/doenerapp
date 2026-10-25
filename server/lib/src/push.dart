import 'dart:async';
import 'dart:convert';

import 'package:doener_models/doener_models.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';
import 'package:sentry/sentry.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'deps.dart';
import 'http.dart';
import 'ranking.dart';
import 'social.dart';

/// Sends to devices; returns the tokens that are gone for good. With [title]
/// and [body] it is a visible notification, without them a silent signal of
/// [data] that the app turns into a notification itself.
abstract interface class Pusher {
  Future<List<String>> send(List<String> tokens, {String? title, String? body, Map<String, String> data = const {}});
}

/// Without `FCM_SERVICE_ACCOUNT` pushes only go to the log.
class LogPusher implements Pusher {
  const LogPusher();

  @override
  Future<List<String>> send(List<String> tokens, {String? title, String? body, Map<String, String> data = const {}}) async {
    if (tokens.isNotEmpty) print('--- push to ${tokens.length} device(s): ${title ?? 'signal'} ${body ?? ''} $data');
    return const [];
  }
}

/// Firebase Cloud Messaging (HTTP v1) for iOS, Android and the web.
class FcmPusher implements Pusher {
  final ServiceAccountCredentials _credentials;
  final String _projectId;
  final http.Client _client;
  AccessCredentials? _access;

  /// [serviceAccountJson] is the key file of a service account allowed to send.
  FcmPusher(String serviceAccountJson, this._client)
      : _credentials = ServiceAccountCredentials.fromJson(serviceAccountJson),
        _projectId = (jsonDecode(serviceAccountJson) as Map<String, dynamic>)['project_id'] as String;

  Future<String> _token() async {
    final access = _access;
    if (access != null && !access.accessToken.hasExpired) return access.accessToken.data;
    _access = await obtainAccessCredentialsViaServiceAccount(_credentials, ['https://www.googleapis.com/auth/firebase.messaging'], _client);
    return _access!.accessToken.data;
  }

  @override
  Future<List<String>> send(List<String> tokens, {String? title, String? body, Map<String, String> data = const {}}) async {
    final gone = <String>[];
    for (final token in tokens) {
      final response = await _client.post(
        Uri.parse('https://fcm.googleapis.com/v1/projects/$_projectId/messages:send'),
        headers: {'authorization': 'Bearer ${await _token()}', 'content-type': 'application/json'},
        body: jsonEncode({
          'message': {
            'token': token,
            if (title != null) 'notification': {'title': title, 'body': body},
            'data': data,
            // Android wakes the app for high priority data messages.
            'android': {'priority': 'high'},
            // iOS takes a silent signal only as a background push, which it
            // may delay or drop (low power mode, app swiped away).
            'apns': title != null
                ? {
                    'payload': {
                      'aps': {'sound': 'default'},
                    },
                  }
                : {
                    'headers': {'apns-push-type': 'background', 'apns-priority': '5'},
                    'payload': {
                      'aps': {'content-available': 1},
                    },
                  },
            'webpush': {
              'headers': {'Urgency': 'high'},
            },
          },
        }),
      );
      // An uninstalled app or a reset token: forget it, not an error.
      if (response.statusCode == 404 || response.body.contains('UNREGISTERED')) {
        gone.add(token);
      } else if (response.statusCode >= 400) {
        print('FCM ${response.statusCode}: ${response.body}');
      }
    }
    return gone;
  }
}

/// Sends to [tokens] and drops the ones FCM no longer knows. Errors only get
/// logged: a push must never fail the request that caused it.
Future<void> _send(Deps deps, List<String> tokens, {String? title, String? body, Map<String, String> data = const {}}) async {
  if (tokens.isEmpty) return;
  try {
    final gone = await deps.pusher.send(tokens, title: title, body: body, data: data);
    if (gone.isNotEmpty) {
      await deps.db.execute(Sql.named('DELETE FROM push_tokens WHERE token = ANY(@tokens:_text)'), parameters: {'tokens': gone});
    }
  } catch (e, st) {
    print('Push failed: $e');
    unawaited(Sentry.captureException(e, stackTrace: st));
  }
}

/// How long the details of a push stay fetchable.
const pushEventTtl = Duration(days: 7);

/// Runs once a minute: what pushes were about is kept for [pushEventTtl] only.
Future<void> deleteOldPushEvents(Deps deps) => deps.db.execute(
      Sql.named("DELETE FROM push_events WHERE created_at < now() - @days:int4 * interval '1 day'"),
      parameters: {'days': pushEventTtl.inDays},
    );

/// Recipients: one row per device.
const _recipientColumns = 't.token, t.user_id::text AS user_id, t.fetch_key_hash IS NOT NULL AS has_key';

/// SQL condition: the user `u` takes pushes now, neither paused nor in their
/// quiet hours, which count in the time zone their phone reported last.
const pushableNow = '(u.push_paused_until IS NULL OR u.push_paused_until <= now()) AND NOT (u.quiet_hours AND '
    "in_quiet_hours(u.quiet_days, u.quiet_start, u.quiet_end, now() AT TIME ZONE coalesce(u.time_zone, 'Europe/Berlin')))";

/// One event per user with the text, which the device fetches
/// (`/push-events/<id>`). [pending] ones wait for [pushPending].
Future<List<Map<String, dynamic>>> _insertEvents(
  Deps deps,
  Iterable<String> users, {
  required String type,
  required String title,
  required String body,
  String? placeId,
  String? actorId,
  bool pending = false,
}) async {
  if (users.isEmpty) return const [];
  return query(
    deps.db,
    'INSERT INTO push_events (user_id, type, title, body, place_id, actor_id, pending) '
    'SELECT u::uuid, @type, @title, @body, @place:text, @actor:uuid, @pending:boolean FROM unnest(@users:_text) u '
    'RETURNING id::text AS id, user_id::text AS user_id',
    {'type': type, 'title': title, 'body': body, 'place': placeId, 'actor': actorId, 'pending': pending, 'users': users.toList()},
  );
}

/// A push is only a signal: each event goes to its user's devices with just
/// its type and ID. Shipped clients without a fetch key get a neutral text.
Future<void> _deliver(Deps deps, List<Map<String, dynamic>> recipients, String type, List<Map<String, dynamic>> events) async {
  final (neutralTitle, neutralBody) = neutralPushText(type);
  for (final event in events) {
    final devices = [for (final r in recipients) if (r['user_id'] == event['user_id']) r];
    await _send(deps, [for (final r in devices) if (!(r['has_key'] as bool)) r['token'] as String], title: neutralTitle, body: neutralBody);
    await _send(
      deps,
      [for (final r in devices) if (r['has_key'] as bool) r['token'] as String],
      data: {'type': type, 'id': event['id'] as String},
    );
  }
}

/// Friends who want it hear about a check-in that happens now, with the shop's
/// place in its city. At most every 3 hours per person who checks in. Runs
/// after the response, so it reports errors instead of throwing them.
Future<void> pushCheckIn(Deps deps, AuthUser me, Map<String, dynamic> place, String? foodType) async {
  try {
    await _pushCheckIn(deps, me, place, foodType);
  } catch (e, st) {
    print('Check-in push failed: $e');
    unawaited(Sentry.captureException(e, stackTrace: st));
  }
}

Future<void> _pushCheckIn(Deps deps, AuthUser me, Map<String, dynamic> place, String? foodType) async {
  // In the quiet hours a check-in is over by the morning: no push, the bell shows it.
  final rows = await query(
    deps.db,
    '$friendIdsCte SELECT $_recipientColumns FROM push_tokens t JOIN users u ON u.id = t.user_id '
    'WHERE u.push_friends AND $pushableNow AND t.user_id IN (SELECT id FROM friends) '
    'AND NOT EXISTS (SELECT 1 FROM friend_mutes m WHERE m.user_id = t.user_id AND m.muted_id = @me:uuid)',
    {'me': me.id},
  );
  if (rows.isEmpty) return;
  final due = await queryOne(
    deps.db,
    "UPDATE users SET check_in_pushed_at = now() WHERE id = @me:uuid AND (check_in_pushed_at IS NULL "
    "OR check_in_pushed_at < now() - interval '3 hours') RETURNING id",
    {'me': me.id},
  );
  if (due == null) return;
  final rank = await cityRank(deps.db, place);
  final name = place['name'] as String;
  final placeId = place['google_place_id'] as String;
  final body = rank == null ? 'bei $name' : 'bei $name (Nr. ${rank.$1} in ${rank.$2})';
  final users = {for (final r in rows) r['user_id'] as String};

  // Friends checking in within half an hour become one notification: the
  // event is updated and signalled again under its ID, which replaces the
  // notification on the device. One update, so check-ins at the same moment
  // count each other; not when the first friend is muted, blocked or no
  // friend any more, their name would come back.
  final recent = await query(
    deps.db,
    'UPDATE push_events e SET actors = e.actors + 1, body = @body, place_id = @place, title = a.display_name || CASE '
    "WHEN e.actors = 1 THEN ' und ' || @name || ' essen gerade 🥙' ELSE ' und ' || e.actors || ' weitere essen gerade 🥙' END "
    "FROM (SELECT DISTINCT ON (user_id) id FROM push_events WHERE type = 'friend_check_in' AND user_id = ANY(@users:_uuid) "
    "AND actor_id <> @me:uuid AND created_at > now() - interval '30 minutes' ORDER BY user_id, created_at DESC) latest, users a "
    'WHERE e.id = latest.id AND a.id = e.actor_id '
    'AND NOT EXISTS (SELECT 1 FROM friend_mutes m WHERE m.user_id = e.user_id AND m.muted_id = e.actor_id) '
    'AND NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.blocker_id = e.user_id AND b.blocked_id = e.actor_id) '
    'OR (b.blocker_id = e.actor_id AND b.blocked_id = e.user_id)) '
    "AND EXISTS (SELECT 1 FROM friendships f WHERE f.status = 'accepted' AND ((f.requester_id = e.user_id AND f.addressee_id = e.actor_id) "
    'OR (f.requester_id = e.actor_id AND f.addressee_id = e.user_id))) '
    'RETURNING e.id::text AS id, e.user_id::text AS user_id',
    {'users': users.toList(), 'me': me.id, 'name': me.displayName, 'body': 'zuletzt ${me.displayName} $body', 'place': placeId},
  );
  final merged = {for (final e in recent) e['user_id'] as String};
  final events = [
    ...recent,
    ...await _insertEvents(
      deps,
      users.difference(merged),
      type: 'friend_check_in',
      title: '${me.displayName} isst gerade ${FoodItem.byId(foodType)?.emoji ?? '🥙'}',
      body: body,
      placeId: placeId,
      actorId: me.id,
    ),
  ];
  await _deliver(deps, rows, 'friend_check_in', events);
}

/// Announced shops that opened lately, once each, to everyone in their city
/// who wants it. Those in their quiet hours or pause get it afterwards.
Future<void> pushOpenings(Deps deps) async {
  final opened = await query(
    deps.db,
    'UPDATE places SET opening_pushed_at = now() WHERE opening_pushed_at IS NULL AND opened_on >= current_date - 1 '
    'AND city IS NOT NULL RETURNING google_place_id, name, city',
  );
  for (final place in opened) {
    final rows = await query(
      deps.db,
      'SELECT $_recipientColumns, $pushableNow AS now FROM push_tokens t JOIN users u ON u.id = t.user_id '
      'WHERE u.push_new_places AND u.city = @city',
      {'city': place['city']},
    );
    final title = 'Neuer Döner in ${place['city']}';
    final body = '${place['name']} hat aufgemacht';
    final placeId = place['google_place_id'] as String;
    final now = {for (final r in rows) if (r['now'] as bool) r['user_id'] as String};
    final later = {for (final r in rows) r['user_id'] as String}.difference(now);
    final events = await _insertEvents(deps, now, type: 'new_place', title: title, body: body, placeId: placeId);
    await _insertEvents(deps, later, type: 'new_place', title: title, body: body, placeId: placeId, pending: true);
    await _deliver(deps, rows, 'new_place', events);
  }
}

/// Runs once a minute: what waited for the end of someone's quiet hours or
/// pause goes out, unless they saw it in the bell already. After a day it is
/// no news any more. The update claims each event once, also with several
/// instances.
Future<void> pushPending(Deps deps) async {
  final due = await query(
    deps.db,
    'UPDATE push_events e SET pending = false FROM users u WHERE e.pending AND u.id = e.user_id '
    "AND ($pushableNow OR e.created_at < now() - interval '1 day') "
    'RETURNING e.id::text AS id, e.user_id::text AS user_id, e.type, '
    "u.push_new_places AND e.created_at >= now() - interval '1 day' "
    'AND (u.inbox_seen_at IS NULL OR u.inbox_seen_at < e.created_at) AS send',
  );
  final events = [for (final e in due) if (e['send'] as bool) e];
  if (events.isEmpty) return;
  final recipients = await query(
    deps.db,
    'SELECT $_recipientColumns FROM push_tokens t WHERE t.user_id = ANY(@users:_uuid)',
    {'users': {for (final e in events) e['user_id'] as String}.toList()},
  );
  for (final type in {for (final e in events) e['type'] as String}) {
    await _deliver(deps, recipients, type, [for (final e in events) if (e['type'] == type) e]);
  }
}

void mountPush(Router router, Deps deps) {
  // PUT /me/push-token {token, platform, latitude, longitude, fetchKey, timeZone}
  // — the device's FCM token; a token moves along when someone else signs in on
  // the device. Without a fetch key (shipped clients) it gets neutral
  // notifications. The time zone is where the quiet hours count.
  router.put('/me/push-token', (Request request) async {
    final me = await requireUser(deps, request);
    final body = await readBody(request, PushTokenRequest.fromJson);
    if (body.token.isEmpty || body.token.length > 4096) throw const ApiException.badRequest('Ungültiger Token');
    final key = body.fetchKey;
    if (key != null && (key.length < 32 || key.length > 200)) throw const ApiException.badRequest('Ungültiger Schlüssel');
    await deps.db.execute(
      Sql.named('INSERT INTO push_tokens (token, user_id, platform, fetch_key_hash) VALUES (@token, @me:uuid, @platform, @key:text) '
          'ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform, '
          'fetch_key_hash = EXCLUDED.fetch_key_hash, updated_at = now()'),
      parameters: {'token': body.token, 'me': me.id, 'platform': body.platform, 'key': key == null ? null : hashToken(key)},
    );
    if (body.latitude != null && body.longitude != null) {
      final city = await nearestCity(deps.db, body.latitude!, body.longitude!);
      if (city != null) {
        await deps.db.execute(Sql.named('UPDATE users SET city = @city WHERE id = @me:uuid'), parameters: {'city': city, 'me': me.id});
      }
    }
    if (body.timeZone case final zone? when zone.length <= 64) {
      await deps.db.execute(
        Sql.named('UPDATE users SET time_zone = @zone WHERE id = @me:uuid AND EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = @zone)'),
        parameters: {'zone': zone, 'me': me.id},
      );
    }
    return noContent();
  });

  // GET /push-events/<id> with `Authorization: Push <fetch key>` — what a push
  // is about, for the device it went to. Not the session: a locked iPhone
  // can't read it, and the web's service worker has none.
  router.get('/push-events/<id>', (Request request, String id) async {
    final header = request.headers['authorization'];
    if (header == null || !header.startsWith('Push ')) throw const ApiException.unauthorized();
    final row = await queryOne(
      deps.db,
      'SELECT e.type, e.title, e.body, e.place_id, e.actor_id::text AS actor_id, a.display_name AS actor_name '
      'FROM push_events e JOIN push_tokens t ON t.user_id = e.user_id LEFT JOIN users a ON a.id = e.actor_id '
      "WHERE e.id = @id:uuid AND t.fetch_key_hash = @hash AND e.created_at > now() - @days:int4 * interval '1 day'",
      {'id': requireUuid(id), 'hash': hashToken(header.substring(5).trim()), 'days': pushEventTtl.inDays},
    );
    if (row == null) throw const ApiException.notFound();
    return json(PushEventDto(
      type: row['type'] as String,
      title: row['title'] as String,
      body: row['body'] as String,
      placeId: row['place_id'] as String?,
      actorId: row['actor_id'] as String?,
      actorName: row['actor_name'] as String?,
    ).toJson());
  });

  router.delete('/me/push-tokens/<token>', (Request request, String token) async {
    final me = await requireUser(deps, request);
    await deps.db.execute(
      Sql.named('DELETE FROM push_tokens WHERE token = @token AND user_id = @me:uuid'),
      parameters: {'token': Uri.decodeComponent(token), 'me': me.id},
    );
    return noContent();
  });

  // Muting a friend stops the pushes about their check-ins, nothing else.
  router.put('/me/mutes/<id>', (Request request, String id) async {
    final me = await requireUser(deps, request);
    await deps.db.execute(
      Sql.named('INSERT INTO friend_mutes (user_id, muted_id) SELECT @me:uuid, id FROM users WHERE id = @id:uuid ON CONFLICT DO NOTHING'),
      parameters: {'me': me.id, 'id': requireUuid(id)},
    );
    return noContent();
  });

  router.delete('/me/mutes/<id>', (Request request, String id) async {
    final me = await requireUser(deps, request);
    await deps.db.execute(
      Sql.named('DELETE FROM friend_mutes WHERE user_id = @me:uuid AND muted_id = @id:uuid'),
      parameters: {'me': me.id, 'id': requireUuid(id)},
    );
    return noContent();
  });
}
