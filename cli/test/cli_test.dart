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

  test('check in and review, then friends see it in the feed and the ranking', () async {
    await db.execute("INSERT INTO places (google_place_id, name, latitude, longitude, city) VALUES "
        "('cli-rank', 'Grill Eck', 47.99, 7.84, 'Freiburg')");
    final ali = await device();
    final ben = await device();
    final aliUser = (await ali.cli(['login', '--email', freshEmail(), '--json'])).json['user'];
    final benUser = (await ben.cli(['login', '--email', freshEmail(), '--json'])).json['user'];
    final aliName = aliUser['displayName'] as String;
    final benName = benUser['displayName'] as String;

    // Ben finds Ali and asks, Ali accepts by asking back
    final found = await ben.cli(['users', '--search', aliName]);
    expect(found.out.split('\n'), contains('$aliName · ${aliUser['id']}'));
    expect((await ben.cli(['befriend', '--user', aliUser['id']])).out, 'Anfrage an $aliName gesendet.');
    expect((await ben.cli(['friends'])).out, '$aliName · Anfrage gesendet · ${aliUser['id']}');
    expect((await ali.cli(['friends'])).out, '$benName · möchte befreundet sein · ${benUser['id']}');
    final accepted = await ali.cli(['befriend', '--user', benUser['id'], '--json']);
    expect(accepted.json['friendship']['status'], 'accepted');
    expect((await ali.cli(['befriend', '--user', benUser['id']])).out, 'Mit $benName befreundet.');
    expect((await ali.cli(['mute', '--user', benUser['id']])).out, '$benName ist stumm.');
    expect((await ali.cli(['friends'])).out, '$benName · befreundet · stumm · ${benUser['id']}');
    final unmuted = await ali.cli(['unmute', '--user', benUser['id'], '--json']);
    expect(unmuted.json['friendship']['muted'], isFalse);
    expect((await ali.cli(['friends', '--json'])).json['friends'].single['muted'], isFalse);
    expect((await ali.cli(['visits'])).out, 'Noch keine Check-ins.');
    expect((await ali.cli(['reviews'])).out, 'Noch keine Bewertungen.');

    final checkin = await ali.cli(['checkin', '--place', 'cli-rank', '--food', 'falafel', '--json']);
    expect(checkin.code, Exit.ok);
    expect(checkin.json['visit']['placeName'], 'Grill Eck');
    expect((await ali.cli(['visits'])).out, endsWith(' Grill Eck · 🧆 Falafel'));

    final review = await ali.cli(
        ['review', '--place', 'cli-rank', '--rate', 'sauce=4,5', '--rate', 'fleisch=4', '--price', '7,50', '--text', 'Lecker', '--json']);
    expect(review.code, Exit.ok);
    expect(review.json['review']['ratings'], {'sauce': 4.5, 'fleisch': 4.0});
    expect(review.json['review']['price'], 750);
    expect((await ali.cli(['reviews'])).out, endsWith(' Grill Eck – 4,5 · 7,50 € · „Lecker“'));
    // A second call only changes what it names, the meat stays as set in the app
    await db.execute(Sql.named("UPDATE reviews SET meat = 'kalb' WHERE id = @id:uuid"), parameters: {'id': review.json['review']['id']});
    final again = await ali.cli(['review', '--place', 'cli-rank', '--rate', 'salat=3', '--json']);
    expect(again.json['review']['ratings'], {'sauce': 4.5, 'fleisch': 4.0});
    expect(again.json['review']['newRatings'], {'salat': 3.0});
    expect([again.json['review']['price'], again.json['review']['text'], again.json['review']['meat']], [750, 'Lecker', 'kalb']);

    final feed = await ben.cli(['feed', '--json']);
    expect(feed.code, Exit.ok);
    expect([for (final item in feed.json['items']) item['type']], ['review', 'visit']);
    final text = (await ben.cli(['feed'])).out.split('\n');
    expect(text, [endsWith('$aliName hat Grill Eck bewertet: 4,0 · „Lecker“'), endsWith('$aliName hat bei Grill Eck eingecheckt')]);
    final first = await ben.cli(['feed', '--limit', '1', '--json']);
    expect(first.json['hasMore'], isTrue);
    final next = await ben.cli(['feed', '--limit', '1', '--cursor', first.json['cursor'], '--json']);
    expect([for (final item in next.json['items']) item['type']], ['visit']);
    expect((await ali.cli(['feed'])).out, 'Noch nichts von deinen Freunden.');

    final bell = await ben.cli(['inbox', '--seen']);
    expect(bell.out.split('\n'), contains(allOf(startsWith('•'), endsWith('$aliName hat bei Grill Eck eingecheckt'))));
    expect((await ben.cli(['inbox', '--json'])).json['seenAt'], isNotNull);
    expect((await ben.cli(['inbox'])).out, allOf(contains('$aliName hat Grill Eck bewertet'), isNot(contains('•'))));
    expect((await ali.cli(['inbox'])).out, 'Nichts Neues in den letzten 7 Tagen.');

    expect((await ben.cli(['friends'])).out, '$aliName · befreundet · ${aliUser['id']}');
    expect((await ben.cli(['friends', '--json'])).json['friends'].single['user']['id'], aliUser['id']);

    final ranking = await ben.cli(['ranking', '--lat', '47.99', '--lon', '7.84']);
    expect(ranking.out, 'Freiburg, Gesamt:\n 1. Grill Eck – 4,0 (1 Bewertung) · 7,50 € · Freunde: $aliName 4,0');
    final sauce = await ben.cli(['ranking', '--lat', '47.99', '--lon', '7.84', '--by', 'sauce', '--json']);
    expect(sauce.json['city'], 'Freiburg');
    expect([for (final entry in sauce.json['entries']) entry['place']['placeId']], ['cli-rank']);
    expect((await ben.cli(['ranking', '--lat', '47.99', '--lon', '7.84', '--max-price', '5'])).out, 'Freiburg, Gesamt: noch keine Läden.');
    expect((await ben.cli(['ranking', '--lat', '47.99', '--lon', '7.84', '--ingredient', 'roteZwiebel'])).out, 'Freiburg, Gesamt: noch keine Läden.');

    expect((await ben.cli(['unfriend', '--user', aliUser['id']])).out, 'Freundschaft mit $aliName beendet.');
    expect((await ali.cli(['friends'])).out, 'Noch keine Freunde.');
    expect((await ben.cli(['feed'])).out, 'Noch nichts von deinen Freunden.');
    await ben.cli(['befriend', '--user', aliUser['id']]);
    expect((await ali.cli(['unfriend', '--user', benUser['id']])).out, 'Anfrage von $benName abgelehnt.');
    expect((await ben.cli(['unfriend', '--user', aliUser['id'], '--json'])).json, {'error': contains('keine Anfrage')});
  });

  test('review, check-in and the rest refuse wrong calls and missing logins', () async {
    final phone = await device();
    expect((await phone.cli(['reviews'])).code, Exit.loggedOut);
    expect((await phone.cli(['checkin', '--place', 'cli-rank'])).code, Exit.loggedOut);
    await phone.cli(['login', '--email', freshEmail()]);

    expect((await phone.cli(['review', '--rate', 'sauce=4'])).code, Exit.usage);
    expect((await phone.cli(['review', '--place', 'cli-rank', '--rate', 'soße=4'])).code, Exit.usage);
    expect((await phone.cli(['checkin', '--place', 'cli-rank', '--food', 'kebab'])).code, Exit.usage);
    expect((await phone.cli(['ranking', '--lat', '48'])).code, Exit.usage);
    expect((await phone.cli(['feed', '--lat', '48'])).code, Exit.usage);
    expect((await phone.cli(['befriend'])).code, Exit.usage);
    expect((await phone.cli(['unfriend'])).code, Exit.usage);
    expect((await phone.cli(['mute', '--user', '00000000-0000-4000-8000-000000000000'])).code, Exit.error);
    expect((await phone.cli(['users', '--search', 'a', '--json'])).json, {'error': 'Mindestens 2 Zeichen'});
    expect((await phone.cli(['befriend', '--user', '00000000-0000-4000-8000-000000000000'])).code, Exit.error);

    final range = await phone.cli(['review', '--place', 'cli-rank', '--rate', 'sauce=7', '--json']);
    expect(range.code, Exit.error);
    expect(range.json, {'error': 'Bewertungen müssen 1–5 in halben Schritten sein'});
    expect((await phone.cli(['checkin', '--place', 'gibts-nicht'])).code, Exit.error);
  });

  test('help, wrong calls and --json', () async {
    final phone = await device();
    final help = await phone.cli(['--help', '--json']);
    expect(help.code, Exit.ok);
    expect([for (final row in help.json['commands']) row['usage']],
        containsAll(['whoami', 'logout', 'friends', 'reviews', 'visits', 'befriend --user <id>']));
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
