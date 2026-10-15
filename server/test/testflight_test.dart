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
  bool submitted = false;
  bool reviewFails = false;

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
      ('GET', '/builds') when request.url.queryParameters['filter[version]'] != '35' => _json({'data': []}),
      ('GET', '/builds') when request.url.queryParameters.containsKey('filter[betaGroups]') => _json({
          'data': [
            if (buildInGroup) {'id': 'b35'},
          ],
        }),
      ('GET', '/builds') => _json({
          'data': [
            {'id': 'b35', 'attributes': {'version': '35', 'processingState': processingState}},
          ],
        }),
      ('POST', '/betaGroups/g-ext/relationships/builds') => () {
          buildInGroup = true;
          return http.Response('', 204);
        }(),
      ('GET', '/builds/b35/buildBetaDetail') => _json({
          'data': {
            'attributes': {'externalBuildState': submitted ? 'IN_BETA_TESTING' : 'READY_FOR_BETA_SUBMISSION'},
          },
        }),
      ('POST', '/betaAppReviewSubmissions') => () {
          if (reviewFails) return _json({}, 500);
          submitted = true;
          return _json({}, 201);
        }(),
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

  test('hands a release build to the group once processed, and retries a failed review', () async {
    expect(await testFlight.distributeBuild('36'), isFalse, reason: 'not uploaded yet');
    apple.processingState = 'PROCESSING';
    expect(await testFlight.distributeBuild('35'), isFalse, reason: 'not processed yet');
    expect(apple.buildInGroup, isFalse);

    apple.processingState = 'VALID';
    apple.reviewFails = true;
    await expectLater(testFlight.distributeBuild('35'), throwsA(isA<http.ClientException>()));
    expect(apple.buildInGroup, isTrue);
    apple.reviewFails = false;
    expect(await testFlight.distributeBuild('35'), isTrue);
    expect(apple.submitted, isTrue);

    final before = apple.requests.length;
    expect(await testFlight.distributeBuild('35'), isTrue);
    expect(apple.requests.skip(before).where((r) => r.startsWith('POST')), isEmpty, reason: 'nothing to do twice');
  });
}
