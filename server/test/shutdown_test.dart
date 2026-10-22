import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doener_server/doener_server.dart';
import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

void main() {
  test('drain lets a running request finish and ends idle keep-alive connections', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final server = await io.serve(
      (Request request) async {
        if (request.url.path == 'slow') {
          started.complete();
          await release.future;
        }
        return Response.ok('done');
      },
      InternetAddress.loopbackIPv4,
      0,
    );
    final client = http.Client();
    addTearDown(client.close);
    final base = 'http://127.0.0.1:${server.port}';
    // Leaves a keep-alive connection open, as browsers do.
    expect((await client.get(Uri.parse('$base/fast'))).body, 'done');

    final slow = http.get(Uri.parse('$base/slow'));
    await started.future;
    var drained = false;
    final draining = drain(server).then((_) => drained = true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(drained, isFalse, reason: 'the slow request is still running');

    release.complete();
    expect((await slow).body, 'done');
    await draining.timeout(const Duration(seconds: 2));
  });

  final env = Platform.environment;
  final port = int.tryParse(env['TEST_DB_PORT'] ?? '');
  if (port == null) {
    test('server shutdown', () {}, skip: 'TEST_DB_PORT not set');
    return;
  }

  // A database of its own: the server's scheduled jobs must not touch the API tests' data.
  setUpAll(() async {
    final admin = await Connection.open(
      Endpoint(
        host: env['TEST_DB_HOST'] ?? 'localhost',
        port: port,
        database: 'postgres',
        username: env['TEST_DB_USER'] ?? 'postgres',
        password: env['TEST_DB_PASSWORD'],
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    await admin.execute('DROP DATABASE IF EXISTS doener_shutdown_test WITH (FORCE)');
    await admin.execute('CREATE DATABASE doener_shutdown_test');
    await admin.close();
  });

  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    test('the server exits cleanly on $signal', () async {
      // Started from source, the server compiles first; on a busy machine that takes a while.
      final server = await Process.start(
        Platform.resolvedExecutable,
        ['bin/server.dart'],
        environment: {
          'APP_ENV': 'development',
          'PORT': '0',
          'WEB_DIR': '/nonexistent',
          'DB_HOST': env['TEST_DB_HOST'] ?? 'localhost',
          'DB_PORT': '$port',
          'DB_NAME': 'doener_shutdown_test',
          'DB_USER': env['TEST_DB_USER'] ?? 'postgres',
          'DB_PASSWORD': env['TEST_DB_PASSWORD'] ?? '',
        },
      );
      addTearDown(() => server.kill(ProcessSignal.sigkill));
      final lines = server.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
      final output = <String>[];
      lines.listen(output.add);
      server.stderr.transform(utf8.decoder).listen(output.add);
      final listening = await lines
          .firstWhere((line) => line.startsWith('Listening on :'))
          .timeout(const Duration(minutes: 4), onTimeout: () => fail(output.join('\n')));
      final health = await http.get(Uri.parse('http://127.0.0.1:${listening.split(':').last}/api/v1/health'));
      expect(health.statusCode, 200);

      server.kill(signal);
      expect(await server.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect(output, contains('Shutting down'));
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
