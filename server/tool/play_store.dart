// Google Play listing and releases through the Play Developer API (README,
// „App Store und Play“), with the service account from ~/.secrets. Texts come
// from docs/store/<locale>/, pictures from docs/play/. Each command is one
// edit that is committed at the end; with managed publishing on, nothing goes
// live until Robin publishes in the Play Console.
//
//   with-secret GOOGLE_DOENER_PLAY_KEY_BASE64 -- dart run tool/play_store.dart <command>
//
// status                  tracks with their releases
// listing                 name, texts, contact, icon, feature graphic, screenshots (de-DE, en-US)
// release <versionCode>   that bundle to production and into review
import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;

const _package = 'com.robinchoice.doener';
const _api = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/$_package';
const _upload = 'https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/$_package';

/// Play language → folder in docs/store and feature graphic in docs/play.
const _languages = {'de-DE': 'de', 'en-US': 'en'};
const _releaseNotes = {'de-DE': 'Erste Version.', 'en-US': 'First release.'};

final _client = http.Client();
late String _accessToken;

Future<void> _login() async {
  final key = jsonDecode(utf8.decode(base64.decode(Platform.environment['GOOGLE_DOENER_PLAY_KEY_BASE64']!.trim())))
      as Map<String, dynamic>;
  final assertion = JWT({
    'iss': key['client_email'],
    'scope': 'https://www.googleapis.com/auth/androidpublisher',
    'aud': 'https://oauth2.googleapis.com/token',
  }).sign(RSAPrivateKey(key['private_key'] as String), algorithm: JWTAlgorithm.RS256, expiresIn: const Duration(minutes: 30));
  final response = await _client.post(Uri.parse('https://oauth2.googleapis.com/token'),
      body: {'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer', 'assertion': assertion});
  if (response.statusCode != 200) throw http.ClientException('token: ${response.statusCode} ${response.body}');
  _accessToken = (jsonDecode(response.body) as Map)['access_token'] as String;
}

Future<Map<String, dynamic>> call(String method, String url, {Object? body, List<int>? bytes}) async {
  final request = http.Request(method, Uri.parse(url))..headers['authorization'] = 'Bearer $_accessToken';
  if (body != null) {
    request.headers['content-type'] = 'application/json';
    request.body = jsonEncode(body);
  }
  if (bytes != null) {
    request.headers['content-type'] = 'image/png';
    request.bodyBytes = bytes;
  }
  final response = await http.Response.fromStream(await _client.send(request));
  if (response.statusCode >= 300) throw http.ClientException('$method $url: ${response.statusCode} ${response.body}');
  return response.body.isEmpty ? {} : jsonDecode(response.body) as Map<String, dynamic>;
}

/// Runs [change] in a fresh edit and commits it; without [commit] the edit is
/// thrown away, for reading.
Future<void> edit(Future<void> Function(String edit) change, {bool commit = true}) async {
  final id = (await call('POST', '$_api/edits'))['id'] as String;
  try {
    await change(id);
    if (commit) {
      await call('POST', '$_api/edits/$id:commit');
      print('committed');
    }
  } finally {
    if (!commit) await call('DELETE', '$_api/edits/$id');
  }
}

String text(String locale, String name) => File('../docs/store/$locale/$name.txt').readAsStringSync().trim();

Future<void> status() => edit((id) async {
      for (final track in (await call('GET', '$_api/edits/$id/tracks'))['tracks'] as List? ?? []) {
        for (final release in track['releases'] as List? ?? []) {
          print('${track['track']}: ${release['name']} ${release['versionCodes']} ${release['status']}');
        }
      }
    }, commit: false);

Future<void> listing() => edit((id) async {
      await call('PATCH', '$_api/edits/$id/details',
          body: {'defaultLanguage': 'de-DE', 'contactEmail': 'hello@pleasance.org', 'contactWebsite': 'https://pleasance.org'});
      for (final MapEntry(key: language, value: short) in _languages.entries) {
        await call('PUT', '$_api/edits/$id/listings/$language', body: {
          'language': language,
          'title': text(language, 'name'),
          'shortDescription': text(language, 'short-description'),
          'fullDescription': text(language, 'description'),
        });
        // The app is German only, so both languages show the German screens.
        final images = {
          'icon': [File('../docs/play/icon-512.png')],
          'featureGraphic': [File('../docs/play/feature-$short.png')],
          'phoneScreenshots': (Directory('../docs/play/de').listSync().whereType<File>().where((f) => f.path.endsWith('.png')).toList()
            ..sort((a, b) => a.path.compareTo(b.path))),
        };
        for (final MapEntry(key: type, value: files) in images.entries) {
          await call('DELETE', '$_api/edits/$id/listings/$language/$type');
          for (final file in files) {
            await call('POST', '$_upload/edits/$id/listings/$language/$type?uploadType=media', bytes: file.readAsBytesSync());
          }
        }
        print('$language: listing and ${images['phoneScreenshots']!.length} screenshots');
      }
    });

Future<void> release(String versionCode) => edit((id) async {
      await call('PUT', '$_api/edits/$id/tracks/production', body: {
        'track': 'production',
        'releases': [
          {
            'versionCodes': [versionCode],
            'status': 'completed',
            'releaseNotes': [
              for (final MapEntry(key: language, value: text) in _releaseNotes.entries) {'language': language, 'text': text},
            ],
          },
        ],
      });
      print('production: $versionCode, sent for review');
    });

Future<void> main(List<String> args) async {
  if (Platform.environment['GOOGLE_DOENER_PLAY_KEY_BASE64'] == null) {
    stderr.writeln('GOOGLE_DOENER_PLAY_KEY_BASE64 is required');
    exit(1);
  }
  try {
    await _login();
    switch (args) {
      case ['status']:
        await status();
      case ['listing']:
        await listing();
      case ['release', final versionCode]:
        await release(versionCode);
      default:
        stderr.writeln('usage: dart run tool/play_store.dart status | listing | release <versionCode>');
        exit(64);
    }
  } finally {
    _client.close();
  }
}
