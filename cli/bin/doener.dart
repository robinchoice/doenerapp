import 'dart:convert';
import 'dart:io';

import 'package:doener_cli/cli.dart';

Future<void> main(List<String> arguments) async {
  final code = await run(
    arguments,
    Io(
      env: Platform.environment,
      out: stdout.writeln,
      err: stderr.writeln,
      ask: (question) async {
        stderr.write(question);
        return stdin.readLineSync(encoding: utf8) ?? '';
      },
      stdin: () => stdin.transform(utf8.decoder).join(),
    ),
  );
  await stdout.flush();
  exit(code);
}
