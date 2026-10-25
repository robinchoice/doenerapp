import 'dart:convert';
import 'dart:io';

/// Name of the compiled file and of its config folder.
const slug = 'doener';

/// The live API, `--define=CLI_URL=…` at compile time names another.
const defaultUrl = String.fromEnvironment('CLI_URL', defaultValue: 'https://doener-api.pleasance.org');

/// The token of this device and the address it belongs to: it never goes elsewhere.
typedef Session = ({String url, String token});

/// XDG_CONFIG_HOME wherever it is set, else the usual place of the platform.
String sessionFile(Map<String, String> env) {
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
  final base = env['XDG_CONFIG_HOME'] ??
      (Platform.isMacOS
          ? '$home/Library/Application Support'
          : Platform.isWindows
              ? env['APPDATA'] ?? '$home/AppData/Roaming'
              : '$home/.config');
  return '$base/$slug/session.json';
}

Future<Session?> loadSession(Map<String, String> env) async {
  try {
    final json = jsonDecode(await File(sessionFile(env)).readAsString()) as Map<String, dynamic>;
    return (url: json['url'] as String, token: json['token'] as String);
  } on Object {
    return null;
  }
}

/// Only the user may read the token. dart:io can't create files with a mode,
/// so the folder is closed and the file restricted before the token goes in.
Future<void> saveSession(Map<String, String> env, Session session) async {
  final file = File(sessionFile(env));
  await file.parent.create(recursive: true);
  await removeSession(env);
  await file.create();
  if (!Platform.isWindows) {
    for (final (mode, path) in [('700', file.parent.path), ('600', file.path)]) {
      final chmod = await Process.run('chmod', [mode, path]);
      if (chmod.exitCode != 0) throw FileSystemException('chmod $mode failed', path);
    }
  }
  await file.writeAsString(jsonEncode({'url': session.url, 'token': session.token}));
}

Future<void> removeSession(Map<String, String> env) async {
  final file = File(sessionFile(env));
  if (await file.exists()) await file.delete();
}
