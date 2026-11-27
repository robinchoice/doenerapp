import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:doener_models/discover.dart';
import 'package:pointycastle/export.dart' show AEADParameters, AESEngine, GCMBlockCipher, KeyParameter;
import 'package:postgres/postgres.dart' show Sql;
import 'package:sentry/sentry.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'deps.dart';
import 'http.dart';
import 'moderation.dart';

const _hour = Duration(hours: 1);

// Each SMS costs money and reaches a person: few per account, number and address, and a cap for all.
const maxSmsPerUser = 3;
const maxSmsPerNumber = 3;
const maxSmsPerIp = 10;
const maxSmsPerDay = 200;
const maxPhoneChecksPerUser = 10;

const _unavailable = ApiException(503, 'Die Suche über Handynummern ist gerade nicht verfügbar.');
const _codeWrong = ApiException.badRequest('Der Code stimmt nicht oder ist abgelaufen.');
const _invalidNumber = ApiException.badRequest('Diese Nummer ist ungültig. Gib sie mit Ländervorwahl ein, zum Beispiel +49 151 …');

final _random = Random.secure();

String _phone(Map<String, dynamic> body) {
  final phone = body['phone'];
  if (phone is! String || !e164.hasMatch(phone)) throw _invalidNumber;
  return phone;
}

/// One entry per discoverable account. Only who knows the number, and so
/// holds its OPRF output, finds the entry by its tag and opens the box with id
/// and name (AES-256-GCM, base64 of nonce || ciphertext || tag): the list
/// reveals nobody to the app, and the app's matches stay on the phone.
Map<String, String> directoryEntry(String phoneKeyHex, Map<String, String> profile) {
  final output = hexBytes(phoneKeyHex);
  final nonce = Uint8List.fromList([for (var i = 0; i < 12; i++) _random.nextInt(256)]);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(discoverBoxKey(output)), 128, nonce, Uint8List(0)));
  final sealed = cipher.process(Uint8List.fromList(utf8.encode(jsonEncode(profile))));
  return {'tag': discoverTag(output), 'box': base64Encode([...nonce, ...sealed])};
}

/// About 8 ms per number: off the isolate that serves requests. Null if an
/// element is no valid point. Top-level, so the closure carries nothing else.
Future<List<String>?> _blindEvaluate(OprfServer server, List<Uint8List> elements) => Isolate.run(() {
      try {
        return [for (final element in elements) base64Encode(server.blindEvaluate(element))];
      } on FormatException {
        return null;
      }
    });

/// Accounts confirm their own number by SMS and then find people from their
/// address book who did the same, see `package:doener_models/discover.dart`.
/// Numbers are never stored, only their OPRF output.
void mountDiscover(Router router, Deps deps) {
  OprfServer oprf() => deps.config.oprf ?? (throw _unavailable);

  // Only accounts with a confirmed number search: every account that can try out numbers costs an SMS to a real phone.
  Future<(AuthUser, String)> searcher(Request request) async {
    final me = await requireUser(deps, request);
    final row = await queryOne(deps.db, 'SELECT phone_key FROM users WHERE id = @me:uuid', {'me': me.id});
    final key = row?['phone_key'] as String?;
    if (key == null) throw const ApiException.forbidden('Bestätige zuerst deine eigene Handynummer.');
    oprf();
    return (me, key);
  }

  router.post('/me/phone', (Request request) async {
    final me = await requireUser(deps, request);
    final sms = deps.sms;
    if (sms == null) throw _unavailable;
    final phone = _phone(await readJson(request));
    final key = phoneKey(oprf(), phone);
    // The own limit first, so refused requests don't use up the address others share.
    if (!await rateLimit(deps, 'sms-per-user:${me.id}', maxSmsPerUser, _hour) ||
        !await rateLimit(deps, 'sms-per-ip:${clientIp(request)}', maxSmsPerIp, _hour) ||
        !await rateLimit(deps, 'sms-per-number:$key', maxSmsPerNumber, _hour) ||
        !await rateLimit(deps, 'sms-per-day', maxSmsPerDay, const Duration(days: 1))) {
      throw tooManyRequests;
    }
    // Expired codes go, so their keys don't outlive the confirmation.
    await deps.db.execute('DELETE FROM phone_codes WHERE expires_at < now()');
    final code = randomCode();
    await query(
      deps.db,
      'INSERT INTO phone_codes (user_id, phone_key, code_hash, expires_at) '
      "VALUES (@me:uuid, @key, @hash, now() + @seconds:int4 * interval '1 second')",
      {'me': me.id, 'key': key, 'hash': hashToken(code), 'seconds': loginRequestTtl.inSeconds},
    );
    try {
      await sms.send(phone, 'Dein Code für Lieblingsdöner: $code');
    } catch (e, st) {
      print('SMS failed: $e');
      unawaited(Sentry.captureException(e, stackTrace: st));
      throw const ApiException(502, 'Die SMS ließ sich nicht verschicken. Versuch es später noch einmal.');
    }
    return noContent();
  });

  // The code counts only for the number it was sent to. The newest
  // confirmation wins: a number confirmed by another account before moves to
  // this one, since only one phone receives its SMS now.
  router.post('/me/phone/verify', (Request request) async {
    final me = await requireUser(deps, request);
    if (!await rateLimit(deps, 'phone-checks-per-user:${me.id}', maxPhoneChecksPerUser, const Duration(minutes: 15))) {
      throw tooManyRequests;
    }
    final body = await readJson(request);
    final phone = _phone(body);
    final code = body['code'];
    if (code is! String || !RegExp(r'^\d{6}$').hasMatch(code)) throw _codeWrong;
    final key = phoneKey(oprf(), phone);
    final account = await deps.db.runTx((tx) async {
      await tx.execute(Sql.named('SELECT pg_advisory_xact_lock(hashtextextended(@key, 0))'), parameters: {'key': key});
      final open = await query(
        tx,
        'UPDATE phone_codes SET attempts = attempts + 1 '
        'WHERE user_id = @me:uuid AND phone_key = @key AND expires_at > now() AND attempts < @max:int4 RETURNING code_hash',
        {'me': me.id, 'key': key, 'max': maxCodeAttempts},
      );
      if (!open.any((row) => row['code_hash'] == hashToken(code))) return null;
      await query(tx, 'DELETE FROM phone_codes WHERE user_id = @me:uuid', {'me': me.id});
      await query(tx, 'UPDATE users SET phone_key = NULL WHERE phone_key = @key AND id <> @me:uuid', {'me': me.id, 'key': key});
      return queryOne(tx, 'UPDATE users SET phone_key = @key WHERE id = @me:uuid RETURNING $accountColumns', {'me': me.id, 'key': key});
    });
    if (account == null) throw _codeWrong;
    return json(accountFromRow(deps, account).toJson());
  });

  // Open codes go too, so none of them switches the search back on.
  router.delete('/me/phone', (Request request) async {
    final me = await requireUser(deps, request);
    final account = await deps.db.runTx((tx) async {
      await query(tx, 'DELETE FROM phone_codes WHERE user_id = @me:uuid', {'me': me.id});
      return queryOne(tx, 'UPDATE users SET phone_key = NULL WHERE id = @me:uuid RETURNING $accountColumns', {'me': me.id});
    });
    return json(accountFromRow(deps, account!).toJson());
  });

  // The app blinds the numbers of its address book, the API only applies its key.
  router.post('/discover/evaluate', (Request request) async {
    final (_, own) = await searcher(request);
    final blinded = (await readJson(request))['blinded'];
    if (blinded is! List || blinded.isEmpty || blinded.length > evaluateChunk || blinded.any((e) => e is! String)) {
      throw const ApiException.badRequest('Ungültige Anfrage');
    }
    final List<Uint8List> elements;
    try {
      elements = [for (final e in blinded.cast<String>()) base64Decode(e)];
    } on FormatException {
      throw const ApiException.badRequest('Ungültige Anfrage');
    }
    // Against trying out numbers: a confirmed number checks this many a day, on whichever account it is confirmed.
    if (!await rateLimit(deps, 'discover-numbers:$own', maxDiscoverNumbersPerDay, const Duration(days: 1), cost: blinded.length)) {
      throw const ApiException(429, 'Für heute sind genug Nummern geprüft. Morgen geht es weiter.');
    }
    final evaluated = await _blindEvaluate(oprf(), elements);
    if (evaluated == null) throw const ApiException.badRequest('Ungültige Anfrage');
    return json({'evaluated': evaluated});
  });

  // All of it, so the app compares on the phone and the API learns neither
  // numbers of people without the app nor who is in whose address book.
  router.get('/discover/directory', (Request request) async {
    final (me, _) = await searcher(request);
    final rows = await query(
      deps.db,
      'SELECT u.id, u.display_name, u.phone_key FROM users u '
      'WHERE u.phone_key IS NOT NULL AND u.id <> @me:uuid AND ${notBlocked('u.id')}',
      {'me': me.id},
    );
    return Response.ok(
      jsonEncode({
        'entries': [
          for (final r in rows)
            directoryEntry(r['phone_key'] as String, {'id': r['id'] as String, 'name': r['display_name'] as String}),
        ],
      }),
      headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store'},
    );
  });
}
