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

/// Recipients for [_signal]: one row per device.
const _recipientColumns = 't.token, t.user_id::text AS user_id, t.fetch_key_hash IS NOT NULL AS has_key';

/// A push is only a signal: each recipient gets an event with the text, the
/// device only its type and ID and fetches the rest (`/push-events/<id>`).
/// Shipped clients without a fetch key get a neutral notification instead.
Future<void> _signal(
  Deps deps,
  List<Map<String, dynamic>> recipients, {
  required String type,
  required String title,
  required String body,
  String? placeId,
}) async {
  if (recipients.isEmpty) return;
  final events = await query(
    deps.db,
    'INSERT INTO push_events (user_id, type, title, body, place_id) '
    'SELECT u::uuid, @type, @title, @body, @place:text FROM unnest(@users:_text) u RETURNING id::text AS id, user_id::text AS user_id',
    {
      'type': type,
      'title': title,
      'body': body,
      'place': placeId,
      'users': {for (final r in recipients) r['user_id'] as String}.toList(),
    },
  );
  final (neutralTitle, neutralBody) = neutralPushText(type);
  await _send(deps, [for (final r in recipients) if (!(r['has_key'] as bool)) r['token'] as String], title: neutralTitle, body: neutralBody);
  for (final event in events) {
    await _send(
      deps,
      [for (final r in recipients) if (r['has_key'] as bool && r['user_id'] == event['user_id']) r['token'] as String],
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
  final rows = await query(
    deps.db,
    '$friendIdsCte SELECT $_recipientColumns FROM push_tokens t JOIN users u ON u.id = t.user_id '
    'WHERE u.push_friends AND t.user_id IN (SELECT id FROM friends) '
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
  await _signal(
    deps,
    rows,
    type: 'friend_check_in',
    title: '${me.displayName} isst gerade ${FoodItem.byId(foodType)?.emoji ?? '🥙'}',
    body: rank == null ? 'bei $name' : 'bei $name (Nr. ${rank.$1} in ${rank.$2})',
    placeId: place['google_place_id'] as String,
  );
}

/// Announced shops that opened lately, once each, to everyone in their city who wants it.
Future<void> pushOpenings(Deps deps) async {
  final opened = await query(
    deps.db,
    'UPDATE places SET opening_pushed_at = now() WHERE opening_pushed_at IS NULL AND opened_on >= current_date - 1 '
    'AND city IS NOT NULL RETURNING google_place_id, name, city',
  );
  for (final place in opened) {
    final rows = await query(
      deps.db,
      'SELECT $_recipientColumns FROM push_tokens t JOIN users u ON u.id = t.user_id WHERE u.push_new_places AND u.city = @city',
      {'city': place['city']},
    );
    await _signal(
      deps,
      rows,
      type: 'new_place',
      title: 'Neuer Döner in ${place['city']}',
      body: '${place['name']} hat aufgemacht',
      placeId: place['google_place_id'] as String,
    );
  }
}

void mountPush(Router router, Deps deps) {
  // PUT /me/push-token {token, platform, latitude, longitude, fetchKey} — the
  // device's FCM token; a token moves along when someone else signs in on the
  // device. Without a fetch key (shipped clients) it gets neutral notifications.
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
      'SELECT e.type, e.title, e.body, e.place_id FROM push_events e JOIN push_tokens t ON t.user_id = e.user_id '
      "WHERE e.id = @id:uuid AND t.fetch_key_hash = @hash AND e.created_at > now() - @days:int4 * interval '1 day'",
      {'id': requireUuid(id), 'hash': hashToken(header.substring(5).trim()), 'days': pushEventTtl.inDays},
    );
    if (row == null) throw const ApiException.notFound();
    return json(PushEventDto(
      type: row['type'] as String,
      title: row['title'] as String,
      body: row['body'] as String,
      placeId: row['place_id'] as String?,
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
