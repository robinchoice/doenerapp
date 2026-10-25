import 'package:doener_models/doener_models.dart';

import '../client.dart';
import '../command.dart';
import '../session.dart';

/// The logged-in account, for every command that needs one.
Future<AccountDto> currentUser(Context ctx) async {
  if (ctx.session == null) throw notLoggedIn;
  return parse(await ctx.api.get('/auth/me'), AccountDto.fromJson);
}

/// Like the app: a code by mail. The server decides whether the address may
/// log in, so the closed sign-up and Robin's approval of testers hold.
Future<AuthResponse> _withCode(Context ctx) async {
  final email = (ctx.args.option('email') ?? await ctx.io.ask('E-Mail-Adresse: ')).trim();
  await ctx.api.post('/auth/login', LoginRequest(email: email).toJson());
  ctx.io.err('Der Code ist an $email unterwegs.');
  final code = (await ctx.io.ask('Code aus der Mail: ')).trim();
  return parse(await ctx.api.post('/auth/verify', VerifyRequest(email: email, code: code).toJson()), AuthResponse.fromJson);
}

/// A login link from the mail or from the Kontor's login-link (README, „CLI“).
Future<AuthResponse> _withLink(Context ctx, String link) async {
  final text = link == '-' ? await ctx.io.stdin() : link;
  final token = Uri.tryParse(text.trim())?.queryParameters['token'];
  if (token == null || token.isEmpty) throw const Failure('Der Link ist unvollständig.', Exit.usage);
  return parse(await ctx.api.post('/auth/verify', VerifyRequest(token: token).toJson()), AuthResponse.fromJson);
}

/// Revokes the token of this device on the server and forgets it. An expired
/// token is gone on the server already.
Future<void> _revoke(Context ctx) async {
  if (ctx.session == null) return;
  try {
    await ctx.api.post('/auth/logout');
  } on Failure catch (e) {
    if (e.exitCode != Exit.loggedOut) rethrow;
  }
  await removeSession(ctx.io.env);
}

final auth = <String, Command>{
  'login': Command(
    help: [
      ('login [--email <adresse>]', 'Anmelden mit dem Code aus der Mail'),
      ('login --link <link>|-', 'Anmelden mit einem Login-Link, - liest ihn von stdin'),
    ],
    options: (parser) => parser
      ..addOption('email')
      ..addOption('link'),
    run: (ctx) async {
      // A new login replaces the token of this device, the old one is revoked first.
      await _revoke(ctx);
      final link = ctx.args.option('link');
      final AuthResponse auth;
      try {
        auth = link == null ? await _withCode(ctx) : await _withLink(ctx, link);
      } on Failure catch (e) {
        // A wrong code or used link is a 401, but no missing login
        if (e.exitCode != Exit.loggedOut) rethrow;
        throw Failure(e.message, Exit.error);
      }
      await saveSession(ctx.io.env, (url: ctx.url, token: auth.token));
      return (data: {'user': auth.user.toJson()}, text: 'Angemeldet als ${auth.user.displayName}.');
    },
  ),
  'whoami': Command(
    help: [('whoami', 'Zeigt das angemeldete Konto')],
    run: (ctx) async {
      final user = await currentUser(ctx);
      return (data: {'user': user.toJson()}, text: '${user.displayName}${user.admin ? ' · Admin' : ''}');
    },
  ),
  'logout': Command(
    help: [('logout', 'Abmelden und den Token dieses Geräts widerrufen')],
    run: (ctx) async {
      await _revoke(ctx);
      return (data: {'ok': true}, text: 'Abgemeldet.');
    },
  ),
};
