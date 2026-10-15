import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;

import 'config.dart';

const _api = 'https://api.appstoreconnect.apple.com/v1';
const bundleId = 'com.robinchoice.doener';

/// App Store Connect API for the external TestFlight group ([AscConfig.group]):
/// invites iPhone testers and hands every new build to the group.
class TestFlight {
  final AscConfig config;
  final http.Client client;
  TestFlight(this.config, this.client);

  String _token() => JWT(
        {'iss': config.issuerId, 'aud': 'appstoreconnect-v1'},
        header: {'kid': config.keyId},
      ).sign(ECPrivateKey(config.privateKey), algorithm: JWTAlgorithm.ES256, expiresIn: const Duration(minutes: 10));

  Future<http.Response> _send(String method, String path, {Map<String, String>? query, Object? body}) async {
    final request = http.Request(method, Uri.parse('$_api$path').replace(queryParameters: query))
      ..headers['authorization'] = 'Bearer ${_token()}';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    return http.Response.fromStream(await client.send(request));
  }

  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? query]) async {
    final response = await _send('GET', path, query: query);
    if (response.statusCode != 200) throw http.ClientException('App Store Connect $path: ${response.statusCode} ${response.body}');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<String> _appId() async => ((await _get('/apps', {'filter[bundleId]': bundleId}))['data'] as List).first['id'] as String;

  Future<String> _groupId(String appId) async {
    final groups = (await _get('/apps/$appId/betaGroups'))['data'] as List;
    final group = groups.firstWhere((g) => g['attributes']['name'] == config.group,
        orElse: () => throw StateError('TestFlight group "${config.group}" not found'));
    return group['id'] as String;
  }

  /// Apple mails the invite. Someone who is a tester already is added to the group.
  Future<void> invite(String email) async {
    final group = await _groupId(await _appId());
    final created = await _send('POST', '/betaTesters', body: {
      'data': {
        'type': 'betaTesters',
        'attributes': {'email': email},
        'relationships': {
          'betaGroups': {
            'data': [
              {'type': 'betaGroups', 'id': group},
            ],
          },
        },
      },
    });
    if (created.statusCode == 201) return;
    if (created.statusCode != 409) throw http.ClientException('TestFlight invite: ${created.statusCode} ${created.body}');
    final testers = (await _get('/betaTesters', {'filter[email]': email}))['data'] as List;
    if (testers.isEmpty) throw http.ClientException('TestFlight invite: conflict, but no tester $email');
    final added = await _send('POST', '/betaGroups/$group/relationships/betaTesters', body: {
      'data': [
        {'type': 'betaTesters', 'id': testers.first['id']},
      ],
    });
    if (added.statusCode != 204) throw http.ClientException('TestFlight group: ${added.statusCode} ${added.body}');
  }

  /// Gives the newest processed build to the group and submits it for the beta
  /// review. Apple lets further builds of an approved version through at once.
  /// Returns the build number, or null if there was nothing to do.
  Future<String?> distributeNewestBuild() async {
    final appId = await _appId();
    final builds = (await _get('/builds', {'filter[app]': appId, 'sort': '-uploadedDate', 'limit': '1'}))['data'] as List;
    if (builds.isEmpty) return null;
    final build = builds.first as Map<String, dynamic>;
    final attributes = build['attributes'] as Map<String, dynamic>;
    if (attributes['processingState'] != 'VALID' || attributes['expired'] == true) return null;
    final group = await _groupId(appId);
    final newestInGroup = (await _get('/builds', {'filter[app]': appId, 'filter[betaGroups]': group, 'sort': '-uploadedDate', 'limit': '1'}))['data'] as List;
    if (newestInGroup.isNotEmpty && newestInGroup.first['id'] == build['id']) return null;

    final added = await _send('POST', '/betaGroups/$group/relationships/builds', body: {
      'data': [
        {'type': 'builds', 'id': build['id']},
      ],
    });
    if (added.statusCode != 204) throw http.ClientException('TestFlight build: ${added.statusCode} ${added.body}');
    final review = await _send('POST', '/betaAppReviewSubmissions', body: {
      'data': {
        'type': 'betaAppReviewSubmissions',
        'relationships': {
          'build': {
            'data': {'type': 'builds', 'id': build['id']},
          },
        },
      },
    });
    // 409: submitted already, or this version needs no review.
    if (review.statusCode != 201 && review.statusCode != 409) {
      throw http.ClientException('TestFlight review: ${review.statusCode} ${review.body}');
    }
    return attributes['version'] as String?;
  }
}
