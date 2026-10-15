import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:doener_models/doener_models.dart';
import 'package:mime/mime.dart';
import 'package:postgres/postgres.dart';
import 'package:sentry/sentry.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'deps.dart';
import 'http.dart';
import 'moderation.dart';
import 'places.dart';

const friendIdsCte = 'WITH friends AS ('
    ' SELECT CASE WHEN requester_id = @me:uuid THEN addressee_id ELSE requester_id END AS id'
    ' FROM friendships WHERE status = \'accepted\' AND (requester_id = @me:uuid OR addressee_id = @me:uuid))';

/// Keyset cursor "(timestamp, id)" — stable even when entries share a timestamp.
String encodeCursor(DateTime timestamp, String id) =>
    base64Url.encode(utf8.encode('${timestamp.toUtc().toIso8601String()}|$id'));

(DateTime, String)? decodeCursor(String? cursor) {
  if (cursor == null || cursor.isEmpty) return null;
  try {
    final parts = utf8.decode(base64Url.decode(cursor)).split('|');
    if (parts.length != 2) throw const FormatException();
    return (DateTime.parse(parts[0]), requireUuid(parts[1]));
  } on FormatException {
    throw const ApiException.badRequest('Ungültiger Cursor');
  }
}

void mountSocial(Router router, Deps deps) {
  // GET /feed?cursor[&lat&lon] — friends' check-ins and reviews; with lat/lon
  // also everyone else's reviews around that point. Own activity is not part of it.
  router.get('/feed', (Request request) async {
    final me = await requireUser(deps, request);
    final limit = queryInt(request, 'limit', fallback: 20, min: 1, max: 50);
    final cursor = decodeCursor(request.url.queryParameters['cursor']);
    final around = request.url.queryParameters.containsKey('lat')
        ? radiusParams(queryDouble(request, 'lat'), queryDouble(request, 'lon'), communityRadius)
        : null;

    // One query over both activity types, ordered and limited together — so
    // "hasMore" is exact and nothing gets skipped between pages.
    final rows = await query(
      deps.db,
      '$friendIdsCte SELECT * FROM ('
      '  SELECT \'visit\' AS type, v.id, v.user_id, v.place_id, v.visited_at AS ts, NULL::text AS text,'
      '         NULL::real AS rating, NULL::real AS sauce_rating, NULL::real AS fleisch_rating, NULL::real AS brot_rating,'
      '         NULL::jsonb AS items, NULL::uuid AS photo_id, 0 AS visit_count,'
      '         v.food_type, true AS from_friend'
      '  FROM visits v WHERE v.user_id IN (SELECT id FROM friends)'
      '  UNION ALL'
      '  SELECT \'review\', r.id, r.user_id, r.place_id, r.updated_at, r.text,'
      '         r.rating, r.sauce_rating, r.fleisch_rating, r.brot_rating, $reviewItemsJson, $reviewPhotoId, $reviewVisitCount, NULL,'
      '         r.user_id IN (SELECT id FROM friends)'
      '  FROM reviews r JOIN places p ON p.id = r.place_id WHERE (r.user_id IN (SELECT id FROM friends)'
      '${around == null ? '' : ' OR (r.user_id <> @me:uuid AND ${withinRadius('p')})'}) AND ${notBlocked('r.user_id')}'
      ') f ${cursor == null ? '' : 'WHERE (f.ts, f.id) < (@ts:timestamptz, @id:uuid)'}'
      ' ORDER BY f.ts DESC, f.id DESC LIMIT @limit:int4',
      {
        'me': me.id,
        'limit': limit + 1,
        ...?around,
        if (cursor != null) 'ts': cursor.$1,
        if (cursor != null) 'id': cursor.$2,
      },
    );

    final hasMore = rows.length > limit;
    final page = rows.take(limit).toList();
    final users = await _usersById(deps, page.map((r) => r['user_id'] as String).toSet());
    final places = await _placesById(deps, page.map((r) => r['place_id'] as String).toSet());

    final items = [
      for (final r in page)
        FeedItem(
          id: r['id'] as String,
          type: FeedItemType.values.byName(r['type'] as String),
          user: users[r['user_id']]!,
          place: places[r['place_id']]!,
          timestamp: r['ts'] as DateTime,
          fromFriend: r['from_friend'] as bool,
          rating: r['rating'] as double?,
          ratings: ratingsFromRow(r),
          text: r['text'] as String?,
          foodType: r['food_type'] as String?,
          photoId: r['photo_id'] as String?,
          onSite: r['visit_count'] as int > 0,
          regular: r['visit_count'] as int >= regularVisits,
        ),
    ];
    final last = page.isEmpty ? null : page.last;
    return json(FeedPage(
      items: items,
      cursor: hasMore ? encodeCursor(last!['ts'] as DateTime, last['id'] as String) : null,
      hasMore: hasMore,
    ).toJson());
  });

  router.get('/feed/live', (Request request) async {
    final me = await requireUser(deps, request);
    final rows = await query(
      deps.db,
      '$friendIdsCte SELECT u.id, u.display_name, u.live_until, u.live_food_type, p.google_place_id, p.name '
      'FROM users u JOIN places p ON p.id = u.live_place_id '
      'WHERE u.id IN (SELECT id FROM friends) AND u.live_until > now() ORDER BY u.live_until DESC',
      {'me': me.id},
    );
    return json([
      for (final r in rows)
        LiveStatusDto(
          user: UserDto(id: r['id'] as String, displayName: r['display_name'] as String),
          placeId: r['google_place_id'] as String,
          placeName: r['name'] as String,
          foodType: r['live_food_type'] as String?,
          until: r['live_until'] as DateTime,
        ).toJson(),
    ]);
  });

  router.delete('/me/live-status', (Request request) async {
    final me = await requireUser(deps, request);
    await deps.db.execute(
      Sql.named('UPDATE users SET live_place_id = NULL, live_until = NULL, live_food_type = NULL WHERE id = @id:uuid'),
      parameters: {'id': me.id},
    );
    return noContent();
  });

  router.get('/users/search', (Request request) async {
    final me = await requireUser(deps, request);
    final q = request.url.queryParameters['q']?.trim() ?? '';
    if (q.length < 2) throw const ApiException.badRequest('Mindestens 2 Zeichen');
    final pattern = '${q.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}')}%';
    final rows = await query(
      deps.db,
      'SELECT u.id, u.display_name, ${reviewedPlacesOf('u.id')} AS reviewed_places FROM users u '
      'WHERE u.display_name ILIKE @pattern AND u.id <> @me:uuid AND ${notBlocked('u.id')} '
      'ORDER BY lower(display_name) LIMIT 20',
      {'pattern': pattern, 'me': me.id},
    );
    return json(
      rows.map((r) => userFromRow(r).toJson()).toList(),
    );
  });

  router.get('/friends', (Request request) async {
    final me = await requireUser(deps, request);
    final rows = await query(deps.db, '$_friendshipSelect WHERE f.requester_id = @me:uuid OR f.addressee_id = @me:uuid '
        'ORDER BY f.created_at DESC', {'me': me.id});
    return json(rows.map((r) => _friendshipFromRow(r, me.id).toJson()).toList());
  });

  router.post('/friends/requests', (Request request) async {
    final me = await requireUser(deps, request);
    final body = await readBody(request, FriendRequestBody.fromJson);
    final other = requireUuid(body.userId, 'userId');
    if (other == me.id) throw const ApiException.badRequest('Du kannst dich nicht selbst hinzufügen');
    if (await queryOne(deps.db, 'SELECT 1 FROM users WHERE id = @id:uuid', {'id': other}) == null ||
        await isBlocked(deps, me.id, other)) {
      throw const ApiException.notFound('Nutzer nicht gefunden');
    }

    await deps.db.execute(
      Sql.named('INSERT INTO friendships (requester_id, addressee_id, status) VALUES (@me:uuid, @other:uuid, \'pending\') '
          'ON CONFLICT (LEAST(requester_id, addressee_id), GREATEST(requester_id, addressee_id)) DO NOTHING'),
      parameters: {'me': me.id, 'other': other},
    );
    // If they already asked me, asking back means accepting.
    await deps.db.execute(
      Sql.named('UPDATE friendships SET status = \'accepted\' '
          'WHERE requester_id = @other:uuid AND addressee_id = @me:uuid AND status = \'pending\''),
      parameters: {'me': me.id, 'other': other},
    );
    final row = await queryOne(
      deps.db,
      '$_friendshipSelect WHERE (f.requester_id = @me:uuid AND f.addressee_id = @other:uuid) '
      'OR (f.requester_id = @other:uuid AND f.addressee_id = @me:uuid)',
      {'me': me.id, 'other': other},
    );
    return json(_friendshipFromRow(row!, me.id).toJson());
  });

  router.post('/friends/<id>/accept', (Request request, String id) async {
    final me = await requireUser(deps, request);
    final row = await queryOne(
      deps.db,
      'UPDATE friendships SET status = \'accepted\' WHERE id = @id:uuid AND addressee_id = @me:uuid RETURNING id',
      {'id': requireUuid(id), 'me': me.id},
    );
    if (row == null) throw const ApiException.notFound('Anfrage nicht gefunden');
    final full = await queryOne(deps.db, '$_friendshipSelect WHERE f.id = @id:uuid', {'id': id});
    return json(_friendshipFromRow(full!, me.id).toJson());
  });

  router.delete('/friends/<id>', (Request request, String id) async {
    final me = await requireUser(deps, request);
    final row = await queryOne(
      deps.db,
      'DELETE FROM friendships WHERE id = @id:uuid AND (requester_id = @me:uuid OR addressee_id = @me:uuid) RETURNING id',
      {'id': requireUuid(id), 'me': me.id},
    );
    if (row == null) throw const ApiException.notFound('Freundschaft nicht gefunden');
    return noContent();
  });

  router.get('/me/invite', (Request request) async {
    final me = await requireUser(deps, request);
    // Created on first use; COALESCE keeps two first calls from handing out different links.
    final row = await queryOne(
      deps.db,
      'UPDATE users SET invite_code = COALESCE(invite_code, @code) WHERE id = @id:uuid RETURNING invite_code',
      {'code': randomInviteCode(), 'id': me.id},
    );
    return json(_invite(deps, request, row!['invite_code'] as String).toJson());
  });

  router.post('/me/invite/reset', (Request request) async {
    final me = await requireUser(deps, request);
    return json(_invite(deps, request, await _newInviteCode(deps, me.id)).toJson());
  });

  router.get('/invites/<code>', (Request request, String code) async {
    final inviter = await _inviter(deps, code);
    if (inviter == null) throw const ApiException.notFound('Einladung ungültig');
    return json(inviter.toJson());
  });

  router.post('/invites/<code>/accept', (Request request, String code) async {
    final me = await requireUser(deps, request);
    final inviter = await _inviter(deps, code);
    if (inviter == null) throw const ApiException.notFound('Einladung ungültig');
    if (inviter.id == me.id) throw const ApiException.badRequest('Das ist dein eigener Link');
    if (await isBlocked(deps, me.id, inviter.id)) throw const ApiException.notFound('Einladung ungültig');

    // Sharing the link and opening it count as both sides agreeing — an open
    // request between the two is settled as well.
    final row = await queryOne(
      deps.db,
      'INSERT INTO friendships (requester_id, addressee_id, status) VALUES (@inviter:uuid, @me:uuid, \'accepted\') '
      'ON CONFLICT (LEAST(requester_id, addressee_id), GREATEST(requester_id, addressee_id)) '
      'DO UPDATE SET status = \'accepted\' RETURNING id',
      {'inviter': inviter.id, 'me': me.id},
    );
    final full = await queryOne(deps.db, '$_friendshipSelect WHERE f.id = @id:uuid', {'id': row!['id']});
    return json(_friendshipFromRow(full!, me.id).toJson());
  });

  router.post('/feedback', (Request request) async {
    final me = await requireUser(deps, request);
    final body = await readBody(request, FeedbackRequest.fromJson);
    final message = body.message.trim();
    if (message.length < Validation.feedbackMin || message.length > Validation.feedbackMax) {
      throw const ApiException.badRequest('Nachricht zu kurz oder zu lang');
    }
    List<int>? screenshot;
    if (body.screenshotBase64 != null) {
      try {
        screenshot = base64.decode(body.screenshotBase64!);
      } on FormatException {
        throw const ApiException.badRequest('Screenshot ist kein gültiges Base64');
      }
    }
    await deps.db.execute(
      Sql.named('INSERT INTO feedback (user_id, message, screenshot, app_version, build_number, platform) '
          'VALUES (@user:uuid, @message, @shot:bytea, @version, @build, @platform)'),
      parameters: {
        'user': me.id,
        'message': message,
        'shot': screenshot,
        'version': body.appVersion,
        'build': body.buildNumber,
        'platform': body.platform,
      },
    );
    final to = deps.config.feedbackEmail;
    if (to != null) await _mailFeedback(deps, to, me, message, body, screenshot);
    return noContent();
  });

  router.post('/shop-reports', (Request request) async {
    final me = await requireUser(deps, request);
    final body = await readBody(request, ShopReportRequest.fromJson);
    final name = body.name.trim();
    if (name.length < Validation.shopNameMin) throw const ApiException.badRequest('Name zu kurz');
    await deps.db.execute(
      Sql.named('INSERT INTO shop_reports (user_id, name, hint, latitude, longitude, note) '
          'VALUES (@user:uuid, @name, @hint, @lat, @lon, @note)'),
      parameters: {
        'user': me.id,
        'name': name,
        'hint': Validation.clean(body.hint),
        'lat': body.latitude,
        'lon': body.longitude,
        'note': Validation.clean(body.note),
      },
    );
    return noContent();
  });
}

/// Replying to the mail reaches the tester. A failed mail doesn't fail the
/// request: the feedback is stored already.
Future<void> _mailFeedback(Deps deps, String to, AuthUser me, String message, FeedbackRequest body, List<int>? screenshot) async {
  try {
    final user = await queryOne(deps.db, 'SELECT email FROM users WHERE id = @id:uuid', {'id': me.id});
    final email = user!['email'] as String;
    final firstLine = message.split('\n').first;
    final type = screenshot == null ? null : lookupMimeType('', headerBytes: screenshot);
    await deps.mailer.send(
      to: to,
      subject: 'Feedback von ${me.displayName}: ${firstLine.length > 60 ? '${firstLine.substring(0, 60)}…' : firstLine}',
      text: '$message\n\n--\n${me.displayName} <$email>\nApp ${body.appVersion} (${body.buildNumber}), ${body.platform}',
      replyTo: email,
      attachment: screenshot == null
          ? null
          : (
              fileName: type == null ? 'screenshot' : 'screenshot.${extensionFromMime(type)}',
              contentType: type ?? 'application/octet-stream',
              bytes: screenshot,
            ),
    );
  } catch (e, st) {
    print('Feedback mail failed: $e');
    unawaited(Sentry.captureException(e, stackTrace: st));
  }
}

final _friendshipSelect = 'SELECT f.id, f.status, f.created_at, f.requester_id, f.addressee_id, '
    'r.display_name AS requester_name, a.display_name AS addressee_name, '
    '${reviewedPlacesOf('r.id')} AS requester_places, ${reviewedPlacesOf('a.id')} AS addressee_places FROM friendships f '
    'JOIN users r ON r.id = f.requester_id JOIN users a ON a.id = f.addressee_id';

FriendshipDto _friendshipFromRow(Map<String, dynamic> row, String me) {
  final outgoing = row['requester_id'] == me;
  return FriendshipDto(
    id: row['id'] as String,
    user: outgoing
        ? UserDto(
            id: row['addressee_id'] as String,
            displayName: row['addressee_name'] as String,
            reviewedPlaces: row['addressee_places'] as int,
          )
        : UserDto(
            id: row['requester_id'] as String,
            displayName: row['requester_name'] as String,
            reviewedPlaces: row['requester_places'] as int,
          ),
    status: FriendshipStatus.values.byName(row['status'] as String),
    direction: outgoing ? FriendshipDirection.outgoing : FriendshipDirection.incoming,
    createdAt: row['created_at'] as DateTime,
  );
}

const _inviteAlphabet = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
final _random = Random.secure();

/// Short enough for a tidy link and QR code, still about 58 bits — nobody
/// befriends you by guessing.
String randomInviteCode() =>
    List.generate(10, (_) => _inviteAlphabet[_random.nextInt(_inviteAlphabet.length)]).join();

Future<String> _newInviteCode(Deps deps, String userId) async {
  final code = randomInviteCode();
  await deps.db.execute(
    Sql.named('UPDATE users SET invite_code = @code WHERE id = @id:uuid'),
    parameters: {'code': code, 'id': userId},
  );
  return code;
}

String _publicBase(Deps deps, Request request) => deps.config.publicUrl ?? request.requestedUri.origin;

InviteDto _invite(Deps deps, Request request, String code) =>
    InviteDto(code: code, url: '${_publicBase(deps, request)}/i/$code');

Future<UserDto?> _inviter(Deps deps, String code) async {
  final row = await queryOne(deps.db, 'SELECT id, display_name FROM users WHERE invite_code = @code', {'code': code});
  return row == null ? null : UserDto(id: row['id'] as String, displayName: row['display_name'] as String);
}

/// `/i/<code>` — what a shared invite link shows without the app: a page with
/// a chat preview (Open Graph). Logged-in browsers go on to the web app and
/// make friends there; everyone else may only apply as a tester, a friend's
/// link opens no account (the request remembers whose link it was).
Future<Response> invitePage(Deps deps, Request request, String code) async {
  // All attributes below are double-quoted; slashes stay readable for link previews.
  const escape = HtmlEscape(HtmlEscapeMode.attribute);
  final inviter = await _inviter(deps, code);
  final base = escape.convert(_publicBase(deps, request));

  // Only known codes are echoed into the page, and those consist of [_inviteAlphabet] only.
  final title = inviter == null
      ? 'Einladung nicht gefunden'
      : '${escape.convert(inviter.displayName)} lädt dich in die Döner App ein';
  final content = inviter == null
      ? '<p>Der Link wurde zurückgesetzt oder ist falsch.</p><a class="button" href="/">Zur Döner App</a>'
      : '<p>Sieh, wo deine Freunde gerade Döner essen – und iss mit. Die App ist noch im Test: '
          'Bewirb dich, dann schalten wir dich frei.</p>'
          '<a class="button" href="/?von=$code#test">Als Tester bewerben</a>'
          '<a class="button secondary" href="/app?invite=$code">Ich habe schon ein Konto</a>';

  return Response(
    inviter == null ? 404 : 200,
    headers: {'content-type': 'text/html; charset=utf-8'},
    body: '''<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
${inviter == null ? '' : '<script>if (localStorage.getItem("FlutterSecureStorage.session_token")) location.replace("/app?invite=$code");</script>'}
<title>$title</title>
<meta property="og:title" content="$title">
<meta property="og:description" content="Sieh, wo deine Freunde gerade Döner essen – und iss mit.">
<meta property="og:image" content="$base/icons/Icon-512.png">
${inviter == null ? '' : '<meta property="og:url" content="$base/i/$code">'}
<style>
  body { margin: 0; font-family: system-ui, sans-serif; background: #fff8f0; color: #222; }
  main { max-width: 420px; margin: 0 auto; padding: 48px 24px; text-align: center; }
  img { border-radius: 50%; }
  h1 { font-size: 1.5rem; }
  .button { display: block; margin: 12px 0; padding: 14px; border-radius: 12px; background: #ff8c00; color: #fff; text-decoration: none; font-weight: 600; }
  .button.secondary { background: none; color: #ff8c00; border: 2px solid #ff8c00; }
</style>
</head>
<body><main><img src="/icons/Icon-192.png" alt="" width="96" height="96"><h1>$title</h1>$content</main></body>
</html>
''',
  );
}

Future<Map<String, UserDto>> _usersById(Deps deps, Set<String> ids) async {
  if (ids.isEmpty) return {};
  final rows = await query(
    deps.db,
    'SELECT u.id, u.display_name, ${reviewedPlacesOf('u.id')} AS reviewed_places FROM users u WHERE u.id = ANY(@ids:_uuid)',
    {'ids': ids.toList()},
  );
  return {for (final r in rows) r['id'] as String: userFromRow(r)};
}

Future<Map<String, PlaceDto>> _placesById(Deps deps, Set<String> ids) async {
  if (ids.isEmpty) return {};
  final rows = await query(deps.db, 'SELECT * FROM place_view WHERE id = ANY(@ids:_uuid)', {'ids': ids.toList()});
  return {for (final r in rows) r['id'] as String: placeFromRow(r)};
}
