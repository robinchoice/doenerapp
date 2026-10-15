import 'dart:convert';
import 'dart:io';

import 'package:doener_server/doener_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// App Store Connect stand-in: one app, the groups, the newest build and its groups.
class FakeAppStoreConnect {
  final requests = <String>[];
  final testers = <String>{};
  String processingState = 'VALID';
  bool buildInGroup = false;

  http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status);

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path.replaceFirst('/v1', '');
    requests.add('${request.method} $path');
    expect(request.headers['authorization'], startsWith('Bearer ey'));
    return switch ((request.method, path)) {
      ('GET', '/apps') => _json({
          'data': [
            {'id': 'app1'},
          ],
        }),
      ('GET', '/apps/app1/betaGroups') => _json({
          'data': [
            {'id': 'g-int', 'attributes': {'name': 'Doener App Pioniere'}},
            {'id': 'g-ext', 'attributes': {'name': 'Erste Tester'}},
          ],
        }),
      ('POST', '/betaTesters') => () {
          final email = (jsonDecode(request.body) as Map)['data']['attributes']['email'] as String;
          return testers.add(email) ? _json({}, 201) : _json({}, 409);
        }(),
      ('GET', '/betaTesters') => _json({
          'data': [
            {'id': 't1'},
          ],
        }),
      ('POST', '/betaGroups/g-ext/relationships/betaTesters') => http.Response('', 204),
      ('GET', '/builds') when request.url.queryParameters.containsKey('filter[betaGroups]') => _json({
          'data': [
            buildInGroup ? {'id': 'b35'} : {'id': 'b34'},
          ],
        }),
      ('GET', '/builds') => _json({
          'data': [
            {'id': 'b35', 'attributes': {'version': '35', 'processingState': processingState, 'expired': false}},
          ],
        }),
      ('POST', '/betaGroups/g-ext/relationships/builds') => () {
          buildInGroup = true;
          return http.Response('', 204);
        }(),
      ('POST', '/betaAppReviewSubmissions') => _json({}, 201),
      _ => http.Response('unexpected ${request.method} $path', 500),
    };
  }
}

void main() {
  late FakeAppStoreConnect apple;
  late TestFlight testFlight;

  setUpAll(() async {
    // A throwaway key: App Store Connect keys are P-256 in PKCS#8.
    final generated = await Process.run('sh', ['-c', 'openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256']);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');
    apple = FakeAppStoreConnect();
    testFlight = TestFlight(
      AscConfig(keyId: 'KEY', issuerId: 'issuer', privateKey: generated.stdout as String),
      MockClient(apple.handle),
    );
  });

  test('invites a new tester into the external group, and someone known already as well', () async {
    await testFlight.invite('ida@example.org');
    expect(apple.requests.last, 'POST /betaTesters');
    await testFlight.invite('ida@example.org');
    expect(apple.requests.last, 'POST /betaGroups/g-ext/relationships/betaTesters');
  });

  test('hands the newest processed build to the group once', () async {
    apple.processingState = 'PROCESSING';
    expect(await testFlight.distributeNewestBuild(), isNull, reason: 'not processed yet');
    apple.processingState = 'VALID';
    expect(await testFlight.distributeNewestBuild(), '35');
    expect(apple.requests, contains('POST /betaAppReviewSubmissions'));
    expect(await testFlight.distributeNewestBuild(), isNull, reason: 'in the group already');
  });
}
