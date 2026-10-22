import 'dart:convert';
import 'dart:io';

import 'package:doener_models/doener_models.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'deps.dart';
import 'http.dart';

// News about the app: admins write them in the app (Profil → Neuigkeiten) or
// agents as files, and publish them as a card on Start and as a mail to those
// who opted in ("Neuigkeiten per Mail", off by default). Only an admin
// (`ADMIN_EMAILS`) publishes, never an agent: it is a mail to others in
// Robin's name. README, "Neuigkeiten".

const maxTitleLength = 120;
const maxFeatures = 10;
const maxFeatureLength = 300;

/// The card on Start shows news this long after publishing.
const updateCardDays = 30;

const _maxAttempts = 3;

/// Mails per run of [deliverUpdateMails], once a minute.
const _mailsPerRun = 5;

final _htmlEscape = HtmlEscape();

/// A draft file `updates/<slug>.md`:
///
///     # Neuigkeiten in der App
///     - Neues zur App siehst du jetzt als Karte auf Start.
///     - Auf Wunsch kommt es auch per Mail.
({String title, List<String> features}) parseDraft(String slug, String text) {
  String? title;
  final features = <String>[];
  for (final (index, raw) in text.split('\n').indexed) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('# ') && title == null) {
      title = line.substring(2).trim();
    } else if (line.startsWith('- ') && title != null) {
      features.add(line.substring(2).trim());
    } else {
      throw FormatException('updates/$slug.md, line ${index + 1}: expected "# Title" once, then "- Feature"');
    }
  }
  if (title == null || !_validDraft(title, features)) {
    throw FormatException('updates/$slug.md needs a title of up to $maxTitleLength characters '
        'and 1 to $maxFeatures features of up to $maxFeatureLength characters');
  }
  return (title: title, features: features);
}

bool _validDraft(String title, List<String> features) =>
    title.isNotEmpty &&
    title.length <= maxTitleLength &&
    features.isNotEmpty &&
    features.length <= maxFeatures &&
    features.every((f) => f.isNotEmpty && f.length <= maxFeatureLength);

/// All draft files in [dir]; throws on the first broken one.
List<({String slug, String title, List<String> features})> readDrafts(String dir) {
  final directory = Directory(dir);
  if (!directory.existsSync()) return const [];
  final files = directory.listSync().whereType<File>().where((f) => f.path.endsWith('.md')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final drafts = <({String slug, String title, List<String> features})>[];
  for (final file in files) {
    final name = file.uri.pathSegments.last;
    final slug = name.substring(0, name.length - 3);
    final draft = parseDraft(slug, file.readAsStringSync());
    drafts.add((slug: slug, title: draft.title, features: draft.features));
  }
  return drafts;
}

/// On every start. A file becomes a draft once and is never overwritten, so
/// edits in the app stay. The server tests parse all files before a deploy.
Future<void> importDrafts(Deps deps) async {
  final List<({String slug, String title, List<String> features})> drafts;
  try {
    drafts = readDrafts(deps.config.updatesDir);
  } on FormatException catch (e) {
    print('News drafts not imported: ${e.message}');
    return;
  }
  for (final draft in drafts) {
    await deps.db.execute(
      Sql.named('INSERT INTO updates (slug, title, features) VALUES (@slug, @title, @features:_text) ON CONFLICT (slug) DO NOTHING'),
      parameters: {'slug': draft.slug, 'title': draft.title, 'features': draft.features},
    );
  }
}

const _updateColumns = 'u.id::text AS id, u.title, u.features, u.in_app, u.by_mail, u.published_at';

UpdateDto _updateFromRow(Map<String, dynamic> row) => UpdateDto(
      id: row['id'] as String,
      title: row['title'] as String,
      features: (row['features'] as List).cast<String>(),
      inApp: row['in_app'] as bool,
      byMail: row['by_mail'] as bool,
      publishedAt: row['published_at'] as DateTime?,
      sent: row['sent'] as int? ?? 0,
      pending: row['pending'] as int? ?? 0,
      failed: row['failed'] as int? ?? 0,
    );

/// The mail of [update] for the user with [unsubscribeToken]: HTML and plain
/// text, with an unsubscribe link and `List-Unsubscribe` for one click.
({String subject, String text, String html, Map<String, String> headers}) updateMail(
  UpdateDto update,
  String unsubscribeToken,
  String publicUrl,
) {
  final appUrl = '$publicUrl/app';
  final unsubscribePage = '$publicUrl/abmelden?token=$unsubscribeToken';
  String e(String value) => _htmlEscape.convert(value);
  final items = update.features
      .map((f) => '<tr><td valign="top" style="padding:7px 12px 7px 0"><div style="width:10px;height:10px;border-radius:5px;'
          'background:#f2c14e;margin-top:7px"></div></td><td style="padding:7px 0;font-size:16px;line-height:24px;color:#17171a">${e(f)}</td></tr>')
      .join();
  final html = '<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
      '<title>${e(update.title)}</title></head>'
      '<body style="margin:0;padding:0;background:#f4f4f1;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif">'
      '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f4f4f1"><tr><td align="center" style="padding:32px 16px">'
      '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:520px;background:#ffffff;border-radius:16px">'
      '<tr><td style="padding:32px 28px">'
      '<div style="font-size:13px;color:#5e5e66;margin-bottom:8px">Neu in der Döner App</div>'
      '<h1 style="margin:0 0 16px;font-size:24px;line-height:30px;color:#17171a">${e(update.title)}</h1>'
      '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">$items</table>'
      '<div style="height:26px"></div>'
      '<a href="${e(appUrl)}" style="display:inline-block;background:#f2c14e;color:#17171a;font-weight:600;text-decoration:none;'
      'padding:12px 22px;border-radius:999px">Döner App öffnen</a>'
      '</td></tr></table>'
      '<p style="max-width:520px;font-size:12px;line-height:18px;color:#5e5e66;margin:18px auto 0">'
      'Du bekommst diese Mail, weil du in der Döner App „Neuigkeiten per Mail“ eingeschaltet hast.<br>'
      '<a href="${e(unsubscribePage)}" style="color:#5e5e66">Abbestellen</a></p>'
      '</td></tr></table></body></html>';
  final text = [
    'Neu in der Döner App',
    '',
    update.title,
    '',
    for (final f in update.features) '- $f',
    '',
    'Döner App öffnen: $appUrl',
    '',
    '--',
    'Du bekommst diese Mail, weil du in der Döner App „Neuigkeiten per Mail“ eingeschaltet hast.',
    'Abbestellen: $unsubscribePage',
  ].join('\n');
  return (
    subject: 'Neu in der Döner App: ${update.title}',
    text: text,
    html: html,
    headers: {
      'List-Unsubscribe': '<$publicUrl/api/v1/updates/unsubscribe?token=$unsubscribeToken>',
      'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click',
    },
  );
}

/// Sends up to [_mailsPerRun] due mails, a few seconds apart; runs once a
/// minute on every instance. The claim marks a mail `sending`, so no other
/// instance takes it; one that failed waits a minute. A mail whose result
/// wasn't recorded (crash right after sending) stays `sending` rather than
/// going out twice. Who unsubscribed since publishing is skipped.
Future<void> deliverUpdateMails(Deps deps, {Duration pause = const Duration(seconds: 2)}) async {
  final publicUrl = deps.config.publicUrl;
  if (publicUrl == null) return;
  for (var i = 0; i < _mailsPerRun; i++) {
    final row = await queryOne(
      deps.db,
      "UPDATE update_deliveries d SET status = 'sending', attempts = attempts + 1, attempted_at = now() WHERE id = ("
      "SELECT id FROM update_deliveries WHERE status = 'pending' "
      "AND (attempted_at IS NULL OR attempted_at < now() - interval '1 minute') "
      'ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED) '
      'RETURNING d.id::text AS delivery, d.attempts, d.update_id, d.user_id',
    );
    if (row == null) return;
    final details = await queryOne(
      deps.db,
      'SELECT $_updateColumns, s.email, s.updates_consent_at IS NOT NULL AS consent, s.unsubscribe_token::text AS token '
      'FROM updates u, users s WHERE u.id = @update:uuid AND s.id = @user:uuid',
      {'update': row['update_id'], 'user': row['user_id']},
    );
    Future<void> mark(String status) => deps.db.execute(
          Sql.named('UPDATE update_deliveries SET status = @status WHERE id = @id:uuid'),
          parameters: {'status': status, 'id': row['delivery']},
        );
    if (details == null || !(details['consent'] as bool)) {
      await mark('skipped');
      continue;
    }
    final mail = updateMail(_updateFromRow(details), details['token'] as String, publicUrl);
    try {
      await deps.mailer.send(to: details['email'] as String, subject: mail.subject, text: mail.text, html: mail.html, headers: mail.headers);
    } catch (e) {
      // SMTP errors may quote the address; the log only gets the delivery.
      print('News mail ${row['delivery']} failed, attempt ${row['attempts']}: ${e.runtimeType}');
      await mark((row['attempts'] as int) >= _maxAttempts ? 'failed' : 'pending');
      continue;
    }
    await mark('sent');
    await Future<void>.delayed(pause);
  }
}

Future<bool> _setConsent(Deps deps, Request request, {required bool on}) async {
  if (!await rateLimit(deps, 'unsubscribe-per-ip:${clientIp(request)}', 30, const Duration(minutes: 15))) throw tooManyRequests;
  final token = request.url.queryParameters['token'] ?? '';
  if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(token)) return false;
  final row = await queryOne(
    deps.db,
    'UPDATE users SET updates_consent_at = CASE WHEN @on:boolean THEN coalesce(updates_consent_at, now()) END '
    'WHERE unsubscribe_token = @token:uuid RETURNING id',
    {'on': on, 'token': token},
  );
  return row != null;
}

Response _page(String title, String body, {int status = 200}) => Response(
      status,
      body: '<!DOCTYPE html><html lang="de"><head><meta charset="utf-8">'
          '<meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex">'
          '<title>${_htmlEscape.convert(title)} – Döner App</title><style>'
          'body{margin:0;font-family:system-ui,sans-serif;background:#f4f4f1;color:#17171a;line-height:1.5}'
          'main{max-width:480px;margin:0 auto;padding:64px 24px;text-align:center}'
          'button{font:inherit;font-weight:600;border:0;border-radius:999px;padding:12px 24px;background:#f2c14e;color:#17171a;cursor:pointer}'
          'p{color:#5e5e66}</style></head><body><main><h1>${_htmlEscape.convert(title)}</h1>$body</main></body></html>',
      headers: {'content-type': 'text/html; charset=utf-8'},
    );

/// `/abmelden?token=…` from the mail: a button, so link scanners don't
/// unsubscribe anyone by opening the link.
Future<Response> unsubscribePage(Deps deps, Request request) async {
  if (request.method == 'POST') {
    if (!await _setConsent(deps, request, on: false)) {
      return _page('Link ungültig', '<p>Der Link stimmt nicht. Abbestellen kannst du auch in der App unter Einstellungen.</p>', status: 400);
    }
    return _page('Abbestellt', '<p>Du bekommst keine Neuigkeiten mehr per Mail. Wieder einschalten kannst du sie in der App unter Einstellungen.</p>');
  }
  final token = _htmlEscape.convert(request.url.queryParameters['token'] ?? '');
  return _page(
    'Neuigkeiten abbestellen?',
    '<p>Danach bekommst du keine Neuigkeiten zur Döner App mehr per Mail. Dein Konto bleibt, wie es ist.</p>'
        '<form method="post" action="/abmelden?token=$token"><button type="submit">Abbestellen</button></form>',
  );
}

void mountUpdates(Router router, Deps deps) {
  // The newest news for the card on Start, until it is dismissed; 204 if none.
  router.get('/updates/current', (Request request) async {
    final me = await requireUser(deps, request);
    final row = await queryOne(
      deps.db,
      'SELECT $_updateColumns FROM updates u WHERE u.in_app AND u.published_at > now() - @days:int4 * interval \'1 day\' '
      'AND NOT EXISTS (SELECT 1 FROM update_dismissals d WHERE d.update_id = u.id AND d.user_id = @me:uuid) '
      'ORDER BY u.published_at DESC LIMIT 1',
      {'days': updateCardDays, 'me': me.id},
    );
    return row == null ? noContent() : json(_updateFromRow(row).toJson());
  });

  router.post('/updates/<id>/dismiss', (Request request, String id) async {
    final me = await requireUser(deps, request);
    await deps.db.execute(
      Sql.named('INSERT INTO update_dismissals (user_id, update_id) SELECT @me:uuid, id FROM updates WHERE id = @id:uuid ON CONFLICT DO NOTHING'),
      parameters: {'me': me.id, 'id': requireUuid(id)},
    );
    return noContent();
  });

  // One-click unsubscribe from the mail program (List-Unsubscribe-Post).
  router.post('/updates/unsubscribe', (Request request) async {
    if (!await _setConsent(deps, request, on: false)) throw const ApiException.badRequest('Link ungültig');
    return noContent();
  });

  router.get('/admin/updates', (Request request) async {
    await requireAdmin(deps, request);
    final subscribers = await queryOne(deps.db, 'SELECT count(*)::int AS n FROM users WHERE updates_consent_at IS NOT NULL');
    final rows = await query(
      deps.db,
      "SELECT $_updateColumns, count(*) FILTER (WHERE d.status IN ('sent', 'sending'))::int AS sent, "
      "count(*) FILTER (WHERE d.status = 'pending')::int AS pending, count(*) FILTER (WHERE d.status = 'failed')::int AS failed "
      'FROM updates u LEFT JOIN update_deliveries d ON d.update_id = u.id GROUP BY u.id '
      'ORDER BY u.published_at IS NOT NULL, coalesce(u.published_at, u.updated_at) DESC',
    );
    return json(AdminUpdatesDto(subscribers: subscribers!['n'] as int, updates: [for (final r in rows) _updateFromRow(r)]).toJson());
  });

  router.post('/admin/updates', (Request request) async {
    await requireAdmin(deps, request);
    final body = _validated(await readBody(request, UpdateDraftRequest.fromJson));
    final row = await queryOne(
      deps.db,
      'INSERT INTO updates (title, features, in_app, by_mail) VALUES (@title, @features:_text, @app, @mail) RETURNING id::text AS id',
      {'title': body.title, 'features': body.features, 'app': body.inApp, 'mail': body.byMail},
    );
    return json((await _find(deps, row!['id'] as String)).toJson());
  });

  router.put('/admin/updates/<id>', (Request request, String id) async {
    await requireAdmin(deps, request);
    final body = _validated(await readBody(request, UpdateDraftRequest.fromJson));
    final row = await queryOne(
      deps.db,
      'UPDATE updates SET title = @title, features = @features:_text, in_app = @app, by_mail = @mail, updated_at = now() '
      'WHERE id = @id:uuid AND published_at IS NULL RETURNING id',
      {'id': requireUuid(id), 'title': body.title, 'features': body.features, 'app': body.inApp, 'mail': body.byMail},
    );
    if (row == null) throw const ApiException.conflict('Schon veröffentlicht, nicht mehr änderbar.');
    return json((await _find(deps, id)).toJson());
  });

  // The mail as subscribers get it, only to the admin's own address.
  router.post('/admin/updates/<id>/test', (Request request, String id) async {
    final admin = await requireAdmin(deps, request);
    if (!await rateLimit(deps, 'update-tests:${admin.id}', 20, const Duration(hours: 1))) throw tooManyRequests;
    final update = await _find(deps, requireUuid(id));
    final me = await queryOne(deps.db, 'SELECT email, unsubscribe_token::text AS token FROM users WHERE id = @id:uuid', {'id': admin.id});
    final mail = updateMail(update, me!['token'] as String, deps.config.publicUrl ?? request.requestedUri.origin);
    await deps.mailer.send(to: me['email'] as String, subject: '[Test] ${mail.subject}', text: mail.text, html: mail.html, headers: mail.headers);
    return noContent();
  });

  // Publishing shows the card and queues a mail for every subscriber. Only an
  // admin may, never an agent (see the top of this file).
  router.post('/admin/updates/<id>/publish', (Request request, String id) async {
    final admin = await requireAdmin(deps, request);
    if (!await rateLimit(deps, 'update-publish:${admin.id}', 5, const Duration(hours: 1))) throw tooManyRequests;
    await deps.db.runTx((tx) async {
      final row = await queryOne(
        tx,
        'UPDATE updates SET published_at = now() WHERE id = @id:uuid AND published_at IS NULL AND (in_app OR by_mail) '
        'RETURNING by_mail',
        {'id': requireUuid(id)},
      );
      if (row == null) throw const ApiException.conflict('Schon veröffentlicht oder weder App noch Mail gewählt.');
      if (row['by_mail'] as bool) {
        await tx.execute(
          Sql.named('INSERT INTO update_deliveries (update_id, user_id) SELECT @id:uuid, id FROM users WHERE updates_consent_at IS NOT NULL'),
          parameters: {'id': id},
        );
      }
    });
    return json((await _find(deps, id)).toJson());
  });
}

UpdateDraftRequest _validated(UpdateDraftRequest body) {
  final title = body.title.trim();
  final features = [for (final f in body.features) if (f.trim().isNotEmpty) f.trim()];
  if (!_validDraft(title, features)) {
    throw const ApiException.badRequest(
        'Eine Neuigkeit braucht einen Titel bis $maxTitleLength Zeichen und 1 bis $maxFeatures Punkte bis $maxFeatureLength Zeichen.');
  }
  return UpdateDraftRequest(title: title, features: features, inApp: body.inApp, byMail: body.byMail);
}

Future<UpdateDto> _find(Deps deps, String id) async {
  final row = await queryOne(
    deps.db,
    "SELECT $_updateColumns, count(*) FILTER (WHERE d.status IN ('sent', 'sending'))::int AS sent, "
    "count(*) FILTER (WHERE d.status = 'pending')::int AS pending, count(*) FILTER (WHERE d.status = 'failed')::int AS failed "
    'FROM updates u LEFT JOIN update_deliveries d ON d.update_id = u.id WHERE u.id = @id:uuid GROUP BY u.id',
    {'id': id},
  );
  if (row == null) throw const ApiException.notFound();
  return _updateFromRow(row);
}
