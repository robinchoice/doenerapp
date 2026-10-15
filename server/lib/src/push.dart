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

/// Sends notifications to devices; returns the tokens that are gone for good.
abstract interface class Pusher {
  Future<List<String>> send(List<String> tokens, {required String title, required String body, Map<String, String> data});
}

/// Without `FCM_SERVICE_ACCOUNT` pushes only go to the log.
class LogPusher implements Pusher {
  const LogPusher();

  @override
  Future<List<String>> send(List<String> tokens, {required String title, required String body, Map<String, String> data = const {}}) async {
    if (tokens.isNotEmpty) print('--- push to ${tokens.length} device(s): $title — $body $data');
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
  Future<List<String>> send(List<String> tokens, {required String title, required String body, Map<String, String> data = const {}}) async {
    final gone = <String>[];
    for (final token in tokens) {
      final response = await _client.post(
        Uri.parse('https://fcm.googleapis.com/v1/projects/$_projectId/messages:send'),
        headers: {'authorization': 'Bearer ${await _token()}', 'content-type': 'application/json'},
        body: jsonEncode({
          'message': {
            'token': token,
            'notification': {'title': title, 'body': body},
            'data': data,
            'android': {'priority': 'high'},
            'apns': {
              'payload': {
                'aps': {'sound': 'default'},
              },
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
Future<void> _send(Deps deps, List<String> tokens, {required String title, required String body, Map<String, String> data = const {}}) async {
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
    '$friendIdsCte SELECT t.token FROM push_tokens t JOIN users u ON u.id = t.user_id '
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
  await _send(
    deps,
    [for (final r in rows) r['token'] as String],
    title: '${me.displayName} isst gerade ${FoodItem.byId(foodType)?.emoji ?? '🥙'}',
    body: rank == null ? 'bei $name' : 'bei $name (Nr. ${rank.$1} in ${rank.$2})',
    data: {'placeId': place['google_place_id'] as String},
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
      'SELECT t.token FROM push_tokens t JOIN users u ON u.id = t.user_id WHERE u.push_new_places AND u.city = @city',
      {'city': place['city']},
    );
    await _send(
      deps,
      [for (final r in rows) r['token'] as String],
      title: 'Neuer Döner in ${place['city']}',
      body: '${place['name']} hat aufgemacht',
      data: {'placeId': place['google_place_id'] as String},
    );
  }
}

void mountPush(Router router, Deps deps) {
  // PUT /me/push-token {token, platform, latitude, longitude} — the device's FCM
  // token; a token moves along when someone else signs in on the device.
  router.put('/me/push-token', (Request request) async {
    final me = await requireUser(deps, request);
    final body = await readBody(request, PushTokenRequest.fromJson);
    if (body.token.isEmpty || body.token.length > 4096) throw const ApiException.badRequest('Ungültiger Token');
    await deps.db.execute(
      Sql.named('INSERT INTO push_tokens (token, user_id, platform) VALUES (@token, @me:uuid, @platform) '
          'ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform, updated_at = now()'),
      parameters: {'token': body.token, 'me': me.id, 'platform': body.platform},
    );
    if (body.latitude != null && body.longitude != null) {
      final city = await nearestCity(deps.db, body.latitude!, body.longitude!);
      if (city != null) {
        await deps.db.execute(Sql.named('UPDATE users SET city = @city WHERE id = @me:uuid'), parameters: {'city': city, 'me': me.id});
      }
    }
    return noContent();
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
