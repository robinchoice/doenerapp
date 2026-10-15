import 'dart:async';

import 'package:doener_models/doener_models.dart';
import 'package:postgres/postgres.dart';
import 'package:sentry/sentry.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'deps.dart';
import 'http.dart';

/// SQL condition: neither @me nor the user in [column] has blocked the other.
String notBlocked(String column) => 'NOT EXISTS (SELECT 1 FROM blocks b WHERE '
    '(b.blocker_id = @me:uuid AND b.blocked_id = $column) OR (b.blocker_id = $column AND b.blocked_id = @me:uuid))';

Future<bool> isBlocked(Deps deps, String me, String other) async =>
    await queryOne(deps.db, 'SELECT 1 WHERE NOT ${notBlocked('@other:uuid')}', {'me': me, 'other': other}) != null;

/// Reporting reviews and blocking users, as the app stores require for user content.
void mountModeration(Router router, Deps deps) {
  // POST /reviews/<id>/report {reason, note} — mails Robin, once per reporter and review.
  router.post('/reviews/<id>/report', (Request request, String id) async {
    final me = await requireUser(deps, request);
    final body = await readBody(request, ReportRequest.fromJson);
    final note = Validation.clean(body.note);
    if ((note?.length ?? 0) > Validation.reportNoteMax) throw const ApiException.badRequest('Text zu lang');
    final review = await queryOne(
      deps.db,
      'SELECT r.id, r.user_id, r.text, u.display_name, p.name AS place_name, '
      '(SELECT id FROM review_photos WHERE review_id = r.id) AS photo_id '
      'FROM reviews r JOIN users u ON u.id = r.user_id JOIN places p ON p.id = r.place_id WHERE r.id = @id:uuid',
      {'id': requireUuid(id)},
    );
    if (review == null) throw const ApiException.notFound('Bewertung nicht gefunden');
    if (review['user_id'] == me.id) throw const ApiException.badRequest('Das ist deine eigene Bewertung');

    final inserted = await queryOne(
      deps.db,
      'INSERT INTO review_reports (review_id, reporter_id, reason, note) VALUES (@review:uuid, @me:uuid, @reason, @note) '
      'ON CONFLICT (review_id, reporter_id) DO NOTHING RETURNING id',
      {'review': review['id'], 'me': me.id, 'reason': body.reason.name, 'note': note},
    );
    final to = deps.config.feedbackEmail;
    if (inserted != null && to != null) {
      final base = deps.config.publicUrl ?? request.requestedUri.origin;
      await _mailReport(deps, to, me, body.reason, note, review, base);
    }
    return noContent();
  });

  // DELETE /reviews/<id> — admins take down a reported review.
  router.delete('/reviews/<id>', (Request request, String id) async {
    final me = await requireUser(deps, request);
    if (!me.account.admin) throw const ApiException.forbidden('Nur für Admins');
    final row = await queryOne(deps.db, 'DELETE FROM reviews WHERE id = @id:uuid RETURNING id', {'id': requireUuid(id)});
    if (row == null) throw const ApiException.notFound('Bewertung nicht gefunden');
    return noContent();
  });

  router.get('/me/blocks', (Request request) async {
    final me = await requireUser(deps, request);
    final rows = await query(
      deps.db,
      'SELECT u.id, u.display_name FROM blocks b JOIN users u ON u.id = b.blocked_id '
      'WHERE b.blocker_id = @me:uuid ORDER BY lower(u.display_name)',
      {'me': me.id},
    );
    return json([for (final r in rows) UserDto(id: r['id'] as String, displayName: r['display_name'] as String).toJson()]);
  });

  // Blocking ends a friendship or an open request between the two.
  router.put('/me/blocks/<id>', (Request request, String id) async {
    final me = await requireUser(deps, request);
    final other = requireUuid(id);
    if (other == me.id) throw const ApiException.badRequest('Du kannst dich nicht selbst blockieren');
    if (await queryOne(deps.db, 'SELECT 1 FROM users WHERE id = @id:uuid', {'id': other}) == null) {
      throw const ApiException.notFound('Nutzer nicht gefunden');
    }
    await deps.db.runTx((tx) async {
      await tx.execute(
        Sql.named('INSERT INTO blocks (blocker_id, blocked_id) VALUES (@me:uuid, @other:uuid) ON CONFLICT DO NOTHING'),
        parameters: {'me': me.id, 'other': other},
      );
      await tx.execute(
        Sql.named('DELETE FROM friendships WHERE (requester_id = @me:uuid AND addressee_id = @other:uuid) '
            'OR (requester_id = @other:uuid AND addressee_id = @me:uuid)'),
        parameters: {'me': me.id, 'other': other},
      );
    });
    return noContent();
  });

  router.delete('/me/blocks/<id>', (Request request, String id) async {
    final me = await requireUser(deps, request);
    await deps.db.execute(
      Sql.named('DELETE FROM blocks WHERE blocker_id = @me:uuid AND blocked_id = @other:uuid'),
      parameters: {'me': me.id, 'other': requireUuid(id)},
    );
    return noContent();
  });
}

/// A failed mail doesn't fail the request: the report is stored already.
Future<void> _mailReport(
  Deps deps,
  String to,
  AuthUser me,
  ReportReason reason,
  String? note,
  Map<String, dynamic> review,
  String base,
) async {
  try {
    final reporter = await queryOne(deps.db, 'SELECT email FROM users WHERE id = @id:uuid', {'id': me.id});
    final email = reporter!['email'] as String;
    final photo = review['photo_id'] == null ? null : '$base/api/v1/photos/${review['photo_id']}';
    await deps.mailer.send(
      to: to,
      subject: 'Gemeldet: Bewertung von ${review['display_name']} bei ${review['place_name']}',
      text: [
        'Grund: ${reason.label}',
        if (note != null) 'Hinweis: $note',
        '',
        'Bewertung ${review['id']} von ${review['display_name']}:',
        review['text'] as String? ?? '(ohne Text)',
        if (photo != null) 'Foto: $photo',
        '',
        'Entfernen: in der App als Admin am Laden ⋮ → Bewertung entfernen.',
        '--',
        'Gemeldet von ${me.displayName} <$email>',
      ].join('\n'),
      replyTo: email,
    );
  } catch (e, st) {
    print('Report mail failed: $e');
    unawaited(Sentry.captureException(e, stackTrace: st));
  }
}
