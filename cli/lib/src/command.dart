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

/// For commands whose API calls need the login.
void requireLogin(Context ctx) {
  if (ctx.session == null) throw notLoggedIn;
}

/// A number option such as `--lat`; null if it's not given and not [required].
double? numberOption(Context ctx, String name, {bool required = false}) {
  final raw = ctx.args.option(name);
  if (raw == null && !required) return null;
  final value = double.tryParse((raw ?? '').replaceAll(',', '.'));
  if (value == null || !value.isFinite) throw Failure('--$name <zahl> fehlt oder ist keine Zahl.', Exit.usage);
  return value;
}

/// A price in euros (`7,50`) as cents, as the API takes it.
int? centsOption(Context ctx, String name) {
  final euros = numberOption(ctx, name);
  return euros == null ? null : (euros * 100).round();
}

String decimal(double value) => value.toStringAsFixed(1).replaceAll('.', ',');

String euros(int cents) => '${(cents / 100).toStringAsFixed(2).replaceAll('.', ',')} €';

String reviewCount(int count) => count == 1 ? '1 Bewertung' : '$count Bewertungen';

/// `23.10.2026` in local time.
String day(DateTime at) {
  final local = at.toLocal();
  String two(int n) => '$n'.padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year}';
}

/// ` · 🤤 2 🥙 1`, empty without reactions.
String reactionText(Map<String, int> reactions) =>
    reactions.isEmpty ? '' : ' · ${[for (final e in reactions.entries) '${e.key} ${e.value}'].join(' ')}';
