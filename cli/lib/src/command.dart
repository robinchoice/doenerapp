import 'package:args/args.dart';

import 'client.dart';
import 'session.dart';

/// What the CLI needs from the outside, so the tests run it in-process.
class Io {
  final Map<String, String> env;
  final void Function(String text) out;
  final void Function(String text) err;

  /// One line from stdin, after the question on stderr.
  final Future<String> Function(String question) ask;

  /// All of stdin.
  final Future<String> Function() stdin;

  const Io({required this.env, required this.out, required this.err, required this.ask, required this.stdin});
}

class Context {
  final Client api;
  final String url;

  /// The stored session, only if it belongs to [url].
  final Session? session;
  final ArgResults args;
  final Io io;

  const Context({required this.api, required this.url, required this.session, required this.args, required this.io});
}

/// [data] is printed for --json, [text] for people.
typedef Result = ({Object? data, String text});

class Command {
  /// Lines in the help: usage and what it does.
  final List<(String, String)> help;
  final void Function(ArgParser parser)? options;
  final Future<Result> Function(Context ctx) run;

  const Command({required this.help, this.options, required this.run});
}

abstract final class Exit {
  static const ok = 0;
  static const error = 1;
  static const usage = 2;
  static const loggedOut = 3;

  static const all = {'ok': ok, 'error': error, 'usage': usage, 'loggedOut': loggedOut};
}

/// Ends the command with a message and an exit code from [Exit].
class Failure implements Exception {
  final String message;
  final int exitCode;
  const Failure(this.message, this.exitCode);
}

const notLoggedIn = Failure('Nicht angemeldet, bitte zuerst `doener login`.', Exit.loggedOut);
