@Tags(['db'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:doener_cli/cli.dart';
import 'package:doener_server/doener_server.dart';
import 'package:doener_server/src/auth.dart' show hashToken;
import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

/// Runs the CLI in-process against the real server on a free port, with its
/// own database `doener_cli_test` (recreated on every run), like the server
/// tests: set TEST_DB_PORT and optionally TEST_DB_HOST / _USER / _PASSWORD.
class CapturingMailer implements Mailer {
  final sent = <({String to, String text})>[];
  @override
  Future<void> send({
    required String to,
    required String subject,
    required String text,
    String? replyTo,
    MailAttachment? attachment,
    String? html,
    Map<String, String> headers = const {},
  }) async =>
      sent.add((to: to, text: text));
}

void main() {
  final env = Platform.environment;
  final port = int.tryParse(env['TEST_DB_PORT'] ?? '');
  if (port == null) {
    test('cli tests', () {}, skip: 'TEST_DB_PORT not set');
    return;
  }

  late Pool<void> db;
  late Deps deps;
  late HttpServer server;
  late HttpServer closedServer;
  late String url;
  late String closedUrl;
  final mailer = CapturingMailer();

  setUpAll(() async {
    Endpoint endpoint(String database) => Endpoint(
          host: env['TEST_DB_HOST'] ?? 'localhost',
          port: port,
          database: database,
          username: env['TEST_DB_USER'] ?? 'postgres',
          password: env['TEST_DB_PASSWORD'],
        );
    final admin = await Connection.open(endpoint('postgres'), settings: const ConnectionSettings(sslMode: SslMode.disable));
    await admin.execute('DROP DATABASE IF EXISTS doener_cli_test WITH (FORCE)');
    await admin.execute('CREATE DATABASE doener_cli_test');
    await admin.close();

    final config = Config(
      database: endpoint('doener_cli_test'),
      publicUrl: 'https://doener.test',
      webDir: '/nonexistent',
      signupOpen: true,
    );
    db = openPool(config);
    await migrate(db);
    deps = Deps(db: db, config: config, mailer: mailer, httpClient: http.Client());
    final closed = Config(database: config.database, publicUrl: config.publicUrl, webDir: config.webDir);
    server = await shelf_io.serve(buildHandler(deps).call, InternetAddress.loopbackIPv4, 0);
    closedServer = await shelf_io.serve(
        buildHandler(Deps(db: db, config: closed, mailer: mailer, httpClient: deps.httpClient)).call,
        InternetAddress.loopbackIPv4,
        0);
    url = 'http://127.0.0.1:${server.port}';
    closedUrl = 'http://127.0.0.1:${closedServer.port}';
  });

  tearDownAll(() async {
    await server.close(force: true);
    await closedServer.close(force: true);
    deps.httpClient.close();
    await db.close();
  });

  var emails = 0;
  String freshEmail() => 'cli-${emails++}@example.org';
  String lastCode() => RegExp(r'Döner App: (\d{6})').firstMatch(mailer.sent.last.text)!.group(1)!;

  /// One device: its own config folder, so its own token. Answers the code
  /// question from the last mail, the email question with [email]. Adds
  /// --url of the test server unless the call names one.
  Future<Device> device() async => Device((await Directory.systemTemp.createTemp('doener-cli-')).path, () => url, lastCode);

  Future<int> sessionCount(String token) async =>
      (await db.execute(Sql.named('SELECT count(*)::int FROM sessions WHERE token_hash = @hash'), parameters: {'hash': hashToken(token)}))
          .single
          .single as int;

  Future<int> me(String token) async =>
      (await http.get(Uri.parse('$url/api/v1/auth/me'), headers: {'authorization': 'Bearer $token'})).statusCode;

  test('login with the mailed code stores a token only the user can read', () async {
    final email = freshEmail();
    final phone = await device();

    final login = await phone.cli(['login', '--json'], email: email);
    expect(login.code, Exit.ok);
    expect(login.json['user']['displayName'], startsWith('Döner-Fan-'));
    expect(login.err, contains('Der Code ist an $email unterwegs.'));
    expect(mailer.sent.last.to, email);
    final file = File(sessionFile(phone.env));
    expect(file.statSync().mode & 511, 384, reason: '0600');
    expect(file.parent.statSync().mode & 511, 448, reason: '0700');
    expect(await sessionCount(phone.token), 1);

    final whoami = await phone.cli(['whoami', '--json']);
    expect(whoami.code, Exit.ok);
    expect(whoami.json['user']['id'], login.json['user']['id']);
    expect((await phone.cli(['whoami'])).out, login.json['user']['displayName']);
  });

  test('logout revokes the token on the server', () async {
    final phone = await device();
    await phone.cli(['login', '--email', freshEmail()]);
    final token = phone.token;
    expect(await me(token), 200);

    final logout = await phone.cli(['logout']);
    expect(logout.code, Exit.ok);
    expect(logout.out, 'Abgemeldet.');
    expect(await me(token), 401);
    expect(File(sessionFile(phone.env)).existsSync(), isFalse);

    final whoami = await phone.cli(['whoami', '--json']);
    expect(whoami.code, Exit.loggedOut);
    expect(whoami.json, {'error': contains('Nicht angemeldet')});
  });

  test('a login link from stdin logs in, and a new login revokes the old token', () async {
    final email = freshEmail();
    final laptop = await device();
    await laptop.cli(['login', '--email', email]);
    final old = laptop.token;

    final link = await loginLink(deps, email);
    final login = await laptop.cli(['login', '--link', '-', '--json'], stdin: '$link\n');
    expect(login.code, Exit.ok);
    expect(laptop.token, isNot(old));
    expect(await me(old), 401);
    expect(await me(laptop.token), 200);

    // A used link doesn't work twice
    final again = await laptop.cli(['login', '--link', link]);
    expect(again.code, Exit.error);
    expect(again.err, 'Link ungültig oder abgelaufen.');
    expect((await laptop.cli(['login', '--link', 'https://doener.test/login'])).code, Exit.usage);
  });

  test('the token only goes to the address it was issued for', () async {
    final phone = await device();
    await phone.cli(['login', '--email', freshEmail()]);
    // Nothing listens there: without a token for it, the CLI doesn't even ask
    final other = await phone.cli(['whoami', '--url', 'http://127.0.0.1:9']);
    expect(other.code, Exit.loggedOut);
    expect((await phone.cli(['whoami', '--url', '$url/'])).code, Exit.ok);
  });

  test('closed sign-up holds: no mail, no account, no token', () async {
    final email = freshEmail();
    final phone = await device();
    final sent = mailer.sent.length;
    final login = await phone.cli(['login', '--email', email, '--url', closedUrl, '--json']);
    expect(login.code, Exit.error);
    expect(login.json['error'], startsWith('Die Registrierung ist noch geschlossen'));
    expect(mailer.sent.length, sent);
    expect(File(sessionFile(phone.env)).existsSync(), isFalse);
    final account = await db.execute(Sql.named('SELECT 1 FROM users WHERE email = @email'), parameters: {'email': email});
    expect(account, isEmpty);
  });

  test('nearby lists the best shops around', () async {
    await db.execute("INSERT INTO places (google_place_id, name, latitude, longitude, city) VALUES "
        "('cli-near', 'Kebap Haus', 48.0, 7.85, 'Freiburg'), ('cli-far', 'Weit Weg', 52.5, 13.4, 'Berlin')");
    final phone = await device();

    final json = await phone.cli(['nearby', '--lat', '48.0', '--lon', '7.85', '--json']);
    expect(json.code, Exit.ok);
    expect([for (final place in json.json['places']) place['placeId']], ['cli-near']);

    final text = await phone.cli(['nearby', '--lat', '48', '--lon', '7.85', '--by', 'vegan']);
    expect(text.out, 'Vegan:\n 1. Kebap Haus, Freiburg – noch nicht bewertet');

    expect((await phone.cli(['nearby', '--lat', '48'])).code, Exit.usage);
    expect((await phone.cli(['nearby', '--lat', '48', '--lon', '7', '--by', 'fleisch'])).code, Exit.usage);
  });

  test('help, wrong calls and --json', () async {
    final phone = await device();
    final help = await phone.cli(['--help', '--json']);
    expect(help.code, Exit.ok);
    expect([for (final row in help.json['commands']) row['usage']], containsAll(['whoami', 'logout']));
    expect(help.json['exitCodes'], {'ok': 0, 'error': 1, 'usage': 2, 'loggedOut': 3});
    expect((await phone.cli([])).out, startsWith('doener – '));

    final unknown = await phone.cli(['bestellen', '--json']);
    expect(unknown.code, Exit.usage);
    expect(unknown.json, {'error': contains('bestellen')});
    expect((await phone.cli(['whoami', '--gibtsnicht'])).code, Exit.usage);
  });
}

class Device {
  final Map<String, String> env;
  final String Function() _url;
  final String Function() _lastCode;
  Device(String configHome, this._url, this._lastCode) : env = {'XDG_CONFIG_HOME': configHome};

  String get token => (jsonDecode(File(sessionFile(env)).readAsStringSync()) as Map)['token'] as String;

  Future<({int code, String out, String err, dynamic json})> cli(List<String> args,
      {String email = '', String stdin = ''}) async {
    final out = <String>[];
    final err = <String>[];
    final code = await run(
      args.isEmpty || args.contains('--url') ? args : [...args, '--url', _url()],
      Io(
        env: env,
        out: out.add,
        err: err.add,
        ask: (question) async => question.startsWith('Code') ? _lastCode() : email,
        stdin: () async => stdin,
      ),
    );
    final text = out.join('\n');
    return (code: code, out: text, err: err.join('\n'), json: text.startsWith(RegExp(r'[\[{]')) ? jsonDecode(text) : null);
  }
}
