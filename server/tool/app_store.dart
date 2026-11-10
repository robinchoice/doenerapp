// App Store listing and submission from the command line (README, „App Store
// und Play“). Texts come from docs/store/<locale>/, screenshots from
// docs/store/ios/<locale>/{iphone,ipad}/. Every step checks first, so a run
// can be repeated.
//
//   with-secret ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 [REVIEW_EMAIL=… REVIEW_CODE=DOENER_REVIEW_PASSWORD] -- \
//     dart run tool/app_store.dart <command>
//
// status                  app, versions, builds
// prepare [build]         name, texts, category, age rating, review notes, newest
//                         (or given) build, manual release; review login from
//                         REVIEW_EMAIL and REVIEW_CODE
// screenshots             replaces the screenshots of the version being prepared
// submit                  submits the version for App Review
// get <path>              raw GET, e.g. /v1/apps/<id>/appStoreVersions
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:doener_server/doener_server.dart';
import 'package:doener_server/src/testflight.dart' show bundleId;
import 'package:http/http.dart' as http;

const _api = 'https://api.appstoreconnect.apple.com';
const _locales = ['de-DE', 'en-US'];
const _privacyUrl = 'https://doener-api.pleasance.org/datenschutz';
const _supportUrl = 'https://pleasance.org';
const _marketingUrl = 'https://doener-api.pleasance.org';

/// Songgate: the review contact (name, phone, mail) is copied from there.
const _contactFromApp = '6819013473';

const _reviewNotes = '''
Lieblingsdöner is a native Flutter app for rating döner shops in Germany. The app is in German.

Sign-in uses a one-time code sent by email. For the review, enter the demo address, tap "Code schicken" and enter the demo password as the code; no email is sent to that address. Sign-up is still closed for new addresses (they can apply on the landing page), the demo account always works.

Shops come from Google Places around the device's location, rated by people nearby. Outside Germany there are few or no ratings: use "Andere Stadt" on the start screen or move the map to Freiburg im Breisgau, Germany, to see the ranking with real ratings.

Core flows: Start shows friends' activity and the top 3 nearby. Karte (map) shows shops, tap one to see its ratings. Bewerten rates sauce, meat, salad and bread separately. Einchecken (middle button) checks in when you are at a shop. Profil > "Freunde einladen" connects friends by QR code or link.

User-generated content: every rating and check-in has a ⋮ menu to report the rating or block the user; reports reach us by email and admins can remove ratings. Account deletion: Profil > gear icon (Einstellungen) > "Account löschen".''';

late AscConfig _asc;
final _client = http.Client();

String _token() => JWT(
  {'iss': _asc.issuerId, 'aud': 'appstoreconnect-v1'},
  header: {'kid': _asc.keyId},
).sign(ECPrivateKey(_asc.privateKey), algorithm: JWTAlgorithm.ES256, expiresIn: const Duration(minutes: 10));

Future<Map<String, dynamic>> call(String method, String path, {Map<String, String>? query, Object? body}) async {
  final request = http.Request(method, Uri.parse('$_api$path').replace(queryParameters: query))
    ..headers['authorization'] = 'Bearer ${_token()}';
  if (body != null) {
    request.headers['content-type'] = 'application/json';
    request.body = jsonEncode(body);
  }
  final response = await http.Response.fromStream(await _client.send(request));
  if (response.statusCode >= 300) throw http.ClientException('$method $path: ${response.statusCode} ${response.body}');
  return response.body.isEmpty ? {} : jsonDecode(response.body) as Map<String, dynamic>;
}

Future<List<dynamic>> list(String path, [Map<String, String>? query]) async =>
    (await call('GET', path, query: query))['data'] as List;

Map<String, dynamic> one(String type, String id) => {
  'data': {'type': type, 'id': id},
};

Future<Map<String, dynamic>> patch(
  String type,
  String id, {
  Map<String, Object?>? attributes,
  Map<String, Object>? relationships,
}) => call(
  'PATCH',
  '/v1/$type/$id',
  body: {
    'data': {'type': type, 'id': id, 'attributes': ?attributes, 'relationships': ?relationships},
  },
);

Future<Map<String, dynamic>> create(
  String type, {
  Map<String, Object?>? attributes,
  Map<String, Object>? relationships,
}) async =>
    (await call(
          'POST',
          '/v1/$type',
          body: {
            'data': {'type': type, 'attributes': ?attributes, 'relationships': ?relationships},
          },
        ))['data']
        as Map<String, dynamic>;

String text(String locale, String name) => File('../docs/store/$locale/$name.txt').readAsStringSync().trim();

Future<String> appId() async => (await list('/v1/apps', {'filter[bundleId]': bundleId})).first['id'] as String;

Future<Map<String, dynamic>> editableInfo(String app) async =>
    (await list('/v1/apps/$app/appInfos')).firstWhere((i) => i['attributes']['appStoreState'] != 'READY_FOR_SALE')
        as Map<String, dynamic>;

Future<Map<String, dynamic>> editableVersion(String app) async =>
    (await list('/v1/apps/$app/appStoreVersions', {'filter[platform]': 'IOS'})).firstWhere(
          (v) => const {
            'PREPARE_FOR_SUBMISSION',
            'DEVELOPER_REJECTED',
            'REJECTED',
            'METADATA_REJECTED',
          }.contains(v['attributes']['appStoreState']),
        )
        as Map<String, dynamic>;

Future<void> status() async {
  final app = await appId();
  print('app $app');
  for (final info in await list('/v1/apps/$app/appInfos')) {
    print('appInfo ${info['id']} ${info['attributes']['appStoreState']}');
    for (final l in await list('/v1/appInfos/${info['id']}/appInfoLocalizations')) {
      final a = l['attributes'];
      print('  ${a['locale']}: ${a['name']} · ${a['subtitle']}');
    }
  }
  for (final v in await list('/v1/apps/$app/appStoreVersions')) {
    final a = v['attributes'];
    print('version ${a['versionString']} ${a['appStoreState']} release=${a['releaseType']}');
  }
  for (final b in await list('/v1/builds', {'filter[app]': app, 'sort': '-uploadedDate', 'limit': '3'})) {
    final a = b['attributes'];
    print('build ${a['version']} ${a['processingState']} ${a['uploadedDate']}');
  }
}

Future<void> prepare(String? buildNumber) async {
  final app = await appId();
  await patch('apps', app, attributes: {'contentRightsDeclaration': 'USES_THIRD_PARTY_CONTENT'});

  final info = await editableInfo(app);
  await patch(
    'appInfos',
    info['id'] as String,
    relationships: {'primaryCategory': one('appCategories', 'FOOD_AND_DRINK')},
  );
  final infoLocs = await list('/v1/appInfos/${info['id']}/appInfoLocalizations');
  for (final locale in _locales) {
    final attributes = {
      'name': text(locale, 'name'),
      'subtitle': text(locale, 'subtitle'),
      'privacyPolicyUrl': _privacyUrl,
    };
    final existing = infoLocs.where((l) => l['attributes']['locale'] == locale).firstOrNull;
    if (existing == null) {
      await create(
        'appInfoLocalizations',
        attributes: {'locale': locale, ...attributes},
        relationships: {'appInfo': one('appInfos', info['id'] as String)},
      );
    } else {
      await patch('appInfoLocalizations', existing['id'] as String, attributes: attributes);
    }
  }
  print('name, subtitle, privacy policy, category: ok');

  // Ratings, photos and names are visible to everyone nearby; nothing else applies.
  // Apple answers a repeated PATCH with 500, so only once.
  final rating = (await call('GET', '/v1/appInfos/${info['id']}/ageRatingDeclaration'))['data']['attributes'] as Map;
  if (rating['userGeneratedContent'] == null) {
    await patch(
      'ageRatingDeclarations',
      info['id'] as String,
      attributes: {
        'alcoholTobaccoOrDrugUseOrReferences': 'NONE',
        'contests': 'NONE',
        'gamblingSimulated': 'NONE',
        'gunsOrOtherWeapons': 'NONE',
        'horrorOrFearThemes': 'NONE',
        'matureOrSuggestiveThemes': 'NONE',
        'medicalOrTreatmentInformation': 'NONE',
        'profanityOrCrudeHumor': 'NONE',
        'sexualContentGraphicAndNudity': 'NONE',
        'sexualContentOrNudity': 'NONE',
        'violenceCartoonOrFantasy': 'NONE',
        'violenceRealistic': 'NONE',
        'violenceRealisticProlongedGraphicOrSadistic': 'NONE',
        'advertising': false,
        'ageAssurance': false,
        'gambling': false,
        'healthOrWellnessTopics': false,
        'lootBox': false,
        'messagingAndChat': false,
        'parentalControls': false,
        'unrestrictedWebAccess': false,
        'userGeneratedContent': true,
        // Friends see check-ins and react to them.
        'socialMedia': true,
      },
    );
  }
  print('age rating: ok');

  final version = await editableVersion(app);
  final versionId = version['id'] as String;
  await patch(
    'appStoreVersions',
    versionId,
    attributes: {'versionString': '1.0.0', 'releaseType': 'MANUAL', 'copyright': '${DateTime.now().year} Pleasance'},
  );
  final versionLocs = await list('/v1/appStoreVersions/$versionId/appStoreVersionLocalizations');
  for (final locale in _locales) {
    final attributes = {
      'description': text(locale, 'description'),
      'keywords': text(locale, 'keywords'),
      'supportUrl': _supportUrl,
      'marketingUrl': _marketingUrl,
    };
    final existing = versionLocs.where((l) => l['attributes']['locale'] == locale).firstOrNull;
    if (existing == null) {
      await create(
        'appStoreVersionLocalizations',
        attributes: {'locale': locale, ...attributes},
        relationships: {'appStoreVersion': one('appStoreVersions', versionId)},
      );
    } else {
      await patch('appStoreVersionLocalizations', existing['id'] as String, attributes: attributes);
    }
  }
  print('version 1.0.0, manual release, description, keywords: ok');

  final env = Platform.environment;
  final contactVersion = (await list('/v1/apps/$_contactFromApp/appStoreVersions', {'limit': '1'})).first['id'];
  final contact =
      (await call('GET', '/v1/appStoreVersions/$contactVersion/appStoreReviewDetail'))['data']['attributes'] as Map;
  final review = {
    for (final key in ['contactFirstName', 'contactLastName', 'contactPhone', 'contactEmail']) key: contact[key],
    'demoAccountRequired': true,
    if (env['REVIEW_EMAIL'] != null) 'demoAccountName': env['REVIEW_EMAIL'],
    if (env['REVIEW_CODE'] != null) 'demoAccountPassword': env['REVIEW_CODE'],
    'notes': _reviewNotes,
  };
  final detail = (await call('GET', '/v1/appStoreVersions/$versionId/appStoreReviewDetail'))['data'];
  if (detail == null) {
    await create(
      'appStoreReviewDetails',
      attributes: review,
      relationships: {'appStoreVersion': one('appStoreVersions', versionId)},
    );
  } else {
    await patch('appStoreReviewDetails', detail['id'] as String, attributes: review);
  }
  print('review contact, demo account, notes: ok');

  // Free, with Germany as base territory.
  final free = (await list('/v1/apps/$app/appPricePoints', {'filter[territory]': 'DEU', 'limit': '1'})).first['id'];
  await call(
    'POST',
    '/v1/appPriceSchedules',
    body: {
      'data': {
        'type': 'appPriceSchedules',
        'relationships': {
          'app': one('apps', app),
          'baseTerritory': one('territories', 'DEU'),
          'manualPrices': {
            'data': [
              {'type': 'appPrices', 'id': r'${free}'},
            ],
          },
        },
      },
      'included': [
        {
          'type': 'appPrices',
          'id': r'${free}',
          'attributes': {'startDate': null},
          'relationships': {'appPricePoint': one('appPricePoints', free as String)},
        },
      ],
    },
  );
  print('price: free');

  final builds = await list('/v1/builds', {
    'filter[app]': app,
    'filter[processingState]': 'VALID',
    'filter[expired]': 'false',
    'filter[version]': ?buildNumber,
    'sort': '-uploadedDate',
    'limit': '1',
  });
  if (builds.isEmpty) throw StateError('no valid build ${buildNumber ?? ''}');
  await patch('appStoreVersions', versionId, relationships: {'build': one('builds', builds.first['id'] as String)});
  print('build ${builds.first['attributes']['version']}: ok');
}

/// iPhone 6.9" (1320×2868) and iPad 13" (2064×2752), in file name order.
const _screenshotTypes = {'iphone': 'APP_IPHONE_67', 'ipad': 'APP_IPAD_PRO_3GEN_129'};

Future<void> screenshots() async {
  final version = await editableVersion(await appId());
  final locs = await list('/v1/appStoreVersions/${version['id']}/appStoreVersionLocalizations');
  for (final loc in locs) {
    final locale = loc['attributes']['locale'] as String;
    final sets = await list('/v1/appStoreVersionLocalizations/${loc['id']}/appScreenshotSets');
    for (final MapEntry(key: folder, value: type) in _screenshotTypes.entries) {
      final dir = Directory('../docs/store/ios/$locale/$folder');
      if (!dir.existsSync()) continue;
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.png')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      var set = sets.where((s) => s['attributes']['screenshotDisplayType'] == type).firstOrNull;
      if (set != null) {
        for (final shot in await list('/v1/appScreenshotSets/${set['id']}/appScreenshots')) {
          await call('DELETE', '/v1/appScreenshots/${shot['id']}');
        }
      } else {
        set = await create(
          'appScreenshotSets',
          attributes: {'screenshotDisplayType': type},
          relationships: {'appStoreVersionLocalization': one('appStoreVersionLocalizations', loc['id'] as String)},
        );
      }
      for (final file in files) {
        final bytes = file.readAsBytesSync();
        final name = file.uri.pathSegments.last;
        final shot = await create(
          'appScreenshots',
          attributes: {'fileName': name, 'fileSize': bytes.length},
          relationships: {'appScreenshotSet': one('appScreenshotSets', set['id'] as String)},
        );
        for (final op in shot['attributes']['uploadOperations'] as List) {
          final request = http.Request(op['method'] as String, Uri.parse(op['url'] as String))
            ..bodyBytes = bytes.sublist(op['offset'] as int, (op['offset'] as int) + (op['length'] as int));
          for (final h in op['requestHeaders'] as List) {
            request.headers[h['name'] as String] = h['value'] as String;
          }
          final response = await _client.send(request);
          if (response.statusCode >= 300) throw http.ClientException('upload $name: ${response.statusCode}');
        }
        await patch(
          'appScreenshots',
          shot['id'] as String,
          attributes: {'uploaded': true, 'sourceFileChecksum': md5.convert(bytes).toString()},
        );
        print('$locale $folder $name');
      }
    }
  }
}

Future<void> submit() async {
  final app = await appId();
  final version = await editableVersion(app);
  final open = await list('/v1/reviewSubmissions', {'filter[app]': app, 'filter[state]': 'READY_FOR_REVIEW'});
  final submission = open.isNotEmpty
      ? open.first as Map<String, dynamic>
      : await create('reviewSubmissions', attributes: {'platform': 'IOS'}, relationships: {'app': one('apps', app)});
  final items = await list('/v1/reviewSubmissions/${submission['id']}/items');
  if (items.isEmpty) {
    await create(
      'reviewSubmissionItems',
      relationships: {
        'reviewSubmission': one('reviewSubmissions', submission['id'] as String),
        'appStoreVersion': one('appStoreVersions', version['id'] as String),
      },
    );
  }
  await patch('reviewSubmissions', submission['id'] as String, attributes: {'submitted': true});
  print('version ${version['attributes']['versionString']} submitted for App Review');
}

Future<void> main(List<String> args) async {
  final asc = Config.fromEnvironment(Platform.environment).asc;
  if (asc == null) {
    stderr.writeln('ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 are required');
    exit(1);
  }
  _asc = asc;
  try {
    switch (args) {
      case ['status']:
        await status();
      case ['prepare']:
        await prepare(null);
      case ['prepare', final build]:
        await prepare(build);
      case ['screenshots']:
        await screenshots();
      case ['submit']:
        await submit();
      case ['get', final path]:
        print(const JsonEncoder.withIndent('  ').convert(await call('GET', path)));
      default:
        stderr.writeln(
          'usage: dart run tool/app_store.dart status | prepare [build] | screenshots | submit | get <path>',
        );
        exit(64);
    }
  } finally {
    _client.close();
  }
}
