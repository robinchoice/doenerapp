import 'dart:convert';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;

import 'src/client.dart';
import 'src/command.dart';
import 'src/commands/auth.dart';
import 'src/commands/feed.dart';
import 'src/commands/friends.dart';
import 'src/commands/nearby.dart';
import 'src/commands/ranking.dart';
import 'src/commands/reviews.dart';
import 'src/commands/visits.dart';
import 'src/session.dart';

export 'src/command.dart' show Exit, Io;
export 'src/session.dart' show sessionFile;

/// Every command of the CLI. A new one goes in here (README, „CLI“).
final commands = <String, Command>{
  ...auth,
  'nearby': nearby,
  'ranking': ranking,
  'feed': feed,
  'friends': friends,
  ...reviews,
  ...visits,
};

ArgParser _parser(Command? command) {
  final parser = ArgParser()
    ..addFlag('json', negatable: false)
    ..addOption('url')
    ..addFlag('help', abbr: 'h', negatable: false);
  command?.options?.call(parser);
  return parser;
}

const _options = [
  ('--json', 'Genau ein JSON-Wert auf stdout, Fehler als {"error": …}'),
  ('--url <url>', 'Adresse der App (sonst die des letzten Logins, zuerst $defaultUrl)'),
  ('-h, --help', 'Diese Hilfe'),
];

/// For --json the same lines as data, so agents read the commands too.
Result _help() {
  final rows = [for (final command in commands.values) ...command.help];
  final width = [...rows, ..._options].map((row) => row.$1.length).reduce((a, b) => a > b ? a : b) + 2;
  List<String> table(List<(String, String)> list) => [for (final (usage, text) in list) '  ${usage.padRight(width)}$text'];
  List<Map<String, String>> lines(List<(String, String)> list) => [for (final (usage, text) in list) {'usage': usage, 'text': text}];
  return (
    data: {'commands': lines(rows), 'options': lines(_options), 'exitCodes': Exit.all},
    text: [
      '$slug – die Döner-App auf der Befehlszeile',
      '',
      'Aufruf: $slug <befehl> [optionen]',
      '',
      'Befehle:',
      ...table(rows),
      '',
      'Optionen:',
      ...table(_options),
      '',
      'Exit-Codes: 0 erledigt, 1 Fehler (auch Absagen der API), 2 falscher Aufruf, 3 nicht angemeldet',
    ].join('\n'),
  );
}

/// `doener <command> [options]`. With --json, stdout holds exactly one JSON
/// value, the result or {error}; the exit code tells which ([Exit]).
Future<int> run(List<String> arguments, Io io) async {
  var json = arguments.contains('--json');
  final httpClient = http.Client();
  try {
    final name = arguments.firstOrNull ?? '';
    final command = commands[name];
    if (name.isNotEmpty && command == null && !name.startsWith('-')) {
      throw Failure('Unbekannter Befehl „$name“, siehe `$slug --help`.', Exit.usage);
    }
    final args = _parser(command).parse(command == null ? arguments : arguments.skip(1));
    json = args.flag('json');
    final help = args.flag('help');
    if (command == null && !help && arguments.isNotEmpty) throw Failure('Aufruf: $slug <befehl> [optionen]', Exit.usage);
    if (args.rest.isNotEmpty) throw Failure('Unerwartet: ${args.rest.join(' ')}, siehe `$slug --help`.', Exit.usage);

    // The address of the last login, unless --url names another
    final stored = await loadSession(io.env);
    final url = (args.option('url') ?? stored?.url ?? defaultUrl).replaceFirst(RegExp(r'/+$'), '');
    final session = stored?.url == url ? stored : null;
    final api = Client(url, session?.token, httpClient);
    final result = command != null && !help
        ? await command.run(Context(api: api, url: url, session: session, args: args, io: io))
        : _help();
    io.out(json ? const JsonEncoder.withIndent('  ').convert(result.data) : result.text);
    return Exit.ok;
  } on Object catch (error) {
    final failure = switch (error) {
      Failure() => error,
      ArgParserException() => Failure('${error.message}, siehe `$slug --help`.', Exit.usage),
      // Anything else, such as a config folder that can't be written
      _ => Failure('$error', Exit.error),
    };
    if (json) {
      io.out(jsonEncode({'error': failure.message}));
    } else {
      io.err(failure.message);
    }
    return failure.exitCode;
  } finally {
    httpClient.close();
  }
}
