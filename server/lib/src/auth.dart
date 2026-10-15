import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:doener_models/doener_models.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'deps.dart';
import 'http.dart';
import 'testflight.dart';

const loginRequestTtl = Duration(minutes: 15);
const sessionTtl = Duration(days: 180);
const maxLoginRequestsPerHour = 5;
const maxCodeAttempts = 5;

final _random = Random.secure();

String hashToken(String value) => sha256.convert(utf8.encode(value)).toString();

String randomToken() =>
    base64Url.encode(List<int>.generate(32, (_) => _random.nextInt(256))).replaceAll('=', '');

String randomCode() => _random.nextInt(1000000).toString().padLeft(6, '0');

/// Shipped clients show `error` as is, and the app has no language switch, so
/// the message carries both languages.
/// The app offers the tester request on the landing page for it.
const signupClosed = ApiException.forbidden(
  'Die Registrierung ist noch geschlossen, für diese Adresse gibt es noch kein Konto. Bewirb dich als Tester.\n'
  'Sign-up is still closed, there is no account for this address yet. Apply as a tester.',
);

const _accountColumns = 'id, email, display_name, diet, expert_mode';

AccountDto accountFromRow(Deps deps, Map<String, dynamic> row) => AccountDto(
      id: row['id'] as String,
      displayName: row['display_name'] as String,
      diet: Diet.values.byName(row['diet'] as String),
      expertMode: row['expert_mode'] as bool,
      admin: deps.config.adminEmails.contains(row['email']),
    );

class AuthUser {
  final String id;
  final String displayName;
  final AccountDto account;
  AuthUser(this.account)
      : id = account.id,
        displayName = account.displayName;
}

Future<AuthUser> requireUser(Deps deps, Request request) async {
  final header = request.headers['authorization'];
  if (header == null || !header.startsWith('Bearer ')) throw const ApiException.unauthorized();
  final row = await queryOne(
    deps.db,
    'SELECT u.id, u.email, u.display_name, u.diet, u.expert_mode FROM sessions s JOIN users u ON u.id = s.user_id '
    'WHERE s.token_hash = @hash AND s.expires_at > now()',
    {'hash': hashToken(header.substring(7).trim())},
  );
  if (row == null) throw const ApiException.unauthorized('Sitzung abgelaufen');
  return AuthUser(accountFromRow(deps, row));
}

void mountAuth(Router router, Deps deps) {
  router.post('/auth/login', (Request request) async {
    final body = await readBody(request, LoginRequest.fromJson);
    if (!Validation.isValidEmail(body.email)) throw const ApiException.badRequest('Ungültige E-Mail-Adresse');
    final email = Validation.normalizeEmail(body.email);
    // Strangers get no mail. Shipped clients send no invite code, their friends'
    // links only work from the next build on.
    final hasAccount = await queryOne(deps.db, 'SELECT 1 FROM users WHERE email = @email', {'email': email}) != null;
    if (!hasAccount && !await _maySignUp(deps, email)) throw signupClosed;
    await _mailLoginCode(deps, email, inviteCode: Validation.clean(body.inviteCode));
    return noContent();
  });

  // POST /auth/invite {email, platform?} — admins let single testers past the
  // closed sign-up: the account exists first, then the tester logs in like any other.
  router.post('/auth/invite', (Request request) async {
    final admin = await requireAdmin(deps, request);
    final body = await readBody(request, InviteRequest.fromJson);
    if (!Validation.isValidEmail(body.email)) throw const ApiException.badRequest('Ungültige E-Mail-Adresse');
    return json((await inviteTester(deps, Validation.normalizeEmail(body.email), admin, platform: body.platform)).toJson());
  });

  router.post('/auth/verify', (Request request) async {
    final body = await readBody(request, VerifyRequest.fromJson);
    final (email, storedInvite) = await _consumeLoginRequest(deps, body);

    var user = await queryOne(deps.db, 'SELECT $_accountColumns FROM users WHERE email = @email', {'email': email});
    final isNewUser = user == null;
    if (isNewUser) {
      final inviteCode = Validation.clean(body.inviteCode) ?? storedInvite;
      if (!await _maySignUp(deps, email)) throw signupClosed;
      user = await _createUser(deps, email, inviteCode);
    }

    final token = randomToken();
    await deps.db.execute(
      Sql.named('INSERT INTO sessions (token_hash, user_id, expires_at) VALUES (@hash, @user:uuid, @expires)'),
      parameters: {
        'hash': hashToken(token),
        'user': user['id'],
        'expires': DateTime.now().toUtc().add(sessionTtl),
      },
    );
    return json(AuthResponse(token: token, user: accountFromRow(deps, user), isNewUser: isNewUser).toJson());
  });

  router.get('/auth/me', (Request request) async {
    final user = await requireUser(deps, request);
    return json(user.account.toJson());
  });

  router.post('/auth/logout', (Request request) async {
    await requireUser(deps, request);
    final token = request.headers['authorization']!.substring(7).trim();
    await deps.db.execute(Sql.named('DELETE FROM sessions WHERE token_hash = @hash'), parameters: {'hash': hashToken(token)});
    return noContent();
  });

  // PATCH /users/me — name, diet, expert mode; only what is set changes.
  router.patch('/users/me', (Request request) async {
    final user = await requireUser(deps, request);
    final body = await readBody(request, UpdateMeRequest.fromJson);
    final error = body.displayName == null ? null : Validation.displayNameError(body.displayName!);
    if (error != null) throw ApiException.badRequest(error);
    try {
      final row = await queryOne(
        deps.db,
        'UPDATE users SET display_name = coalesce(@name:text, display_name), diet = coalesce(@diet:text, diet), '
        'expert_mode = coalesce(@expert:boolean, expert_mode) WHERE id = @id:uuid '
        'RETURNING $_accountColumns',
        {'name': body.displayName?.trim(), 'diet': body.diet?.name, 'expert': body.expertMode, 'id': user.id},
      );
      return json(accountFromRow(deps, row!).toJson());
    } on UniqueViolationException {
      throw const ApiException.conflict('Der Name ist schon vergeben.');
    }
  });

  // Account deletion — required by the App Store for apps with sign-up.
  router.delete('/users/me', (Request request) async {
    final user = await requireUser(deps, request);
    await deps.db.execute(Sql.named('DELETE FROM users WHERE id = @id:uuid'), parameters: {'id': user.id});
    return noContent();
  });
}

/// Landing page requests from before sign-up closed keep their way in; the
/// 90-day cleanup of `tester_requests` ends this by itself.
final signupClosedAt = DateTime.utc(2026, 10, 15, 14, 30);

/// Closed until Robin opens it: new accounts only for the allowlist, early
/// tester requests or an admin's invite ([inviteTester]). A friend's invite
/// link only makes friends, so testers can't bring in others.
Future<bool> _maySignUp(Deps deps, String email) async {
  final config = deps.config;
  if (config.signupOpen || config.signupAllowlist.contains(email)) return true;
  return await queryOne(
        deps.db,
        'SELECT 1 FROM tester_requests WHERE email = @email AND created_at < @closed '
        "AND created_at > now() - interval '90 days'",
        {'email': email, 'closed': signupClosedAt},
      ) !=
      null;
}

Future<AuthUser> requireAdmin(Deps deps, Request request) async {
  final user = await requireUser(deps, request);
  if (!user.account.admin) throw const ApiException.forbidden('Nur für Admins');
  return user;
}

/// Creates the account if needed and mails the login code. With [platform]
/// `ios`, Apple also mails the TestFlight invite; a failure there leaves the
/// account in place and shows in the result.
Future<InviteResult> inviteTester(Deps deps, String email, AuthUser admin, {String? platform}) async {
  if (await queryOne(deps.db, 'SELECT 1 FROM users WHERE email = @email', {'email': email}) == null) {
    await _createUser(deps, email, null);
  }
  await _mailLoginCode(deps, email, invitedBy: admin.displayName);
  if (platform != 'ios') return const InviteResult();
  final asc = deps.config.asc;
  if (asc == null) return const InviteResult(testFlight: false);
  try {
    await TestFlight(asc, deps.httpClient).invite(email);
    return const InviteResult(testFlight: true);
  } catch (e) {
    print('TestFlight invite for $email failed: $e');
    return const InviteResult(testFlight: false);
  }
}

/// Mails a code and a magic link; [invitedBy] turns it into an invitation.
Future<void> _mailLoginCode(Deps deps, String email, {String? invitedBy, String? inviteCode}) async {
  await deps.db.execute("DELETE FROM login_requests WHERE created_at < now() - interval '1 day'");
  await deps.db.execute('DELETE FROM sessions WHERE expires_at < now()');

  final recent = await queryOne(
    deps.db,
    "SELECT count(*)::int AS n FROM login_requests WHERE email = @email AND created_at > now() - interval '1 hour'",
    {'email': email},
  );
  if ((recent!['n'] as int) >= maxLoginRequestsPerHour) {
    throw const ApiException(429, 'Zu viele Anfragen – bitte später erneut versuchen.');
  }

  final code = randomCode();
  final token = randomToken();
  await deps.db.execute(
    Sql.named('INSERT INTO login_requests (email, code_hash, token_hash, expires_at, invite_code) '
        'VALUES (@email, @code, @token, @expires, @invite:text)'),
    parameters: {
      'invite': inviteCode,
      'email': email,
      'code': hashToken(code),
      'token': hashToken(token),
      'expires': DateTime.now().toUtc().add(loginRequestTtl),
    },
  );

  final publicUrl = deps.config.publicUrl;
  final appUrl = deps.config.appDownloadUrl;
  await deps.mailer.send(
    to: email,
    subject: invitedBy == null ? 'Dein Login-Code: $code' : '$invitedBy lädt dich in die Döner App ein',
    text: '${invitedBy == null ? '' : '$invitedBy hat dir ein Konto in der Döner App angelegt.\n\n'}'
        'Dein Code für die Döner App: $code\n\n'
        '${publicUrl == null ? '' : 'Oder direkt im Browser anmelden:\n$publicUrl/login?token=$token\n\n'}'
        '${invitedBy == null || appUrl == null ? '' : 'Die App für dein Handy:\n$appUrl\n\n'}'
        'Der Code ist ${loginRequestTtl.inMinutes} Minuten gültig. '
        '${invitedBy == null ? 'Falls du das nicht angefordert hast, ignoriere diese Mail einfach.' : 'Danach meldest du dich jederzeit mit dieser Adresse an.'}',
  );
}

/// Validates a code or magic-link token and returns the verified email with
/// the invite code given at the login request.
Future<(String, String?)> _consumeLoginRequest(Deps deps, VerifyRequest body) async {
  final token = Validation.clean(body.token);
  if (token != null) {
    final row = await queryOne(
      deps.db,
      'UPDATE login_requests SET used_at = now() '
      'WHERE token_hash = @hash AND used_at IS NULL AND expires_at > now() RETURNING email, invite_code',
      {'hash': hashToken(token)},
    );
    if (row == null) throw const ApiException.unauthorized('Link ungültig oder abgelaufen.');
    return (row['email'] as String, row['invite_code'] as String?);
  }

  final email = body.email == null ? null : Validation.normalizeEmail(body.email!);
  final code = body.code?.trim();
  if (email == null || code == null) throw const ApiException.badRequest('E-Mail und Code oder Token erforderlich');

  const invalid = ApiException.unauthorized('Code ungültig oder abgelaufen.');
  final row = await queryOne(
    deps.db,
    'SELECT id, code_hash, attempts, invite_code FROM login_requests '
    'WHERE email = @email AND used_at IS NULL AND expires_at > now() ORDER BY created_at DESC LIMIT 1',
    {'email': email},
  );
  if (row == null || (row['attempts'] as int) >= maxCodeAttempts) throw invalid;

  if (row['code_hash'] != hashToken(code)) {
    await deps.db.execute(
      Sql.named('UPDATE login_requests SET attempts = attempts + 1 WHERE id = @id:uuid'),
      parameters: {'id': row['id']},
    );
    throw invalid;
  }
  final used = await queryOne(
    deps.db,
    'UPDATE login_requests SET used_at = now() WHERE id = @id:uuid AND used_at IS NULL RETURNING id',
    {'id': row['id']},
  );
  if (used == null) throw invalid;
  return (email, row['invite_code'] as String?);
}

/// New accounts get a random unique name; the app asks to change it afterwards.
/// [inviteCode] records whose link brought the account in, if it is known.
Future<Map<String, dynamic>> _createUser(Deps deps, String email, String? inviteCode) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    final name = '${Validation.generatedNamePrefix}${1000 + _random.nextInt(9000)}';
    try {
      return (await queryOne(
        deps.db,
        'INSERT INTO users (email, display_name, invited_by) '
        'VALUES (@email, @name, (SELECT id FROM users WHERE invite_code = @invite:text)) '
        'RETURNING $_accountColumns',
        {'email': email, 'name': name, 'invite': inviteCode},
      ))!;
    } on UniqueViolationException catch (e) {
      if (e.constraintName != 'users_display_name') rethrow;
    }
  }
  throw StateError('Could not generate a unique display name');
}
