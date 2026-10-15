import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'auth.dart';
import 'deps.dart';
import 'http.dart';
import 'landing.dart';
import 'moderation.dart';
import 'places.dart';
import 'privacy.dart';
import 'ranking.dart';
import 'shop_pages.dart';
import 'social.dart';

/// Lets iOS open invite and review links in the installed app instead of the browser (Universal Links).
const _appSiteAssociation = {
  'applinks': {
    'details': [
      {
        'appIDs': ['T2F442364K.com.robinchoice.doener'],
        'components': [
          {'/': '/i/*'},
          {'/': '/b/*'},
        ],
      },
    ],
  },
};

/// Lets Android open invite and review links in the installed app (App Links).
/// The fingerprint is the upload key, which signs the APK sent to testers by hand.
/// Once the app is on Play, add the app signing key from the Play Console.
const _assetLinks = [
  {
    'relation': ['delegate_permission/common.handle_all_urls'],
    'target': {
      'namespace': 'android_app',
      'package_name': 'com.robinchoice.doener',
      'sha256_cert_fingerprints': [
        '79:10:D1:31:7D:E1:F6:1A:B8:4A:1D:65:5B:14:A2:8B:29:52:0D:CA:6A:61:76:16:40:A5:B2:F1:86:22:FF:FF',
      ],
    },
  },
];

/// API under `/api/v1`, the landing page under `/` and `/en`, the Flutter web
/// build (if present) everywhere else, e.g. `/app`.
Handler buildHandler(Deps deps) {
  final api = Router(notFoundHandler: (_) => json({'error': 'Nicht gefunden'}, status: 404))
    // The deploy job waits until the public URL reports its commit as revision.
    ..get('/health', (Request _) async {
      try {
        await deps.db.execute('SELECT 1');
        return json({'status': 'ok', 'revision': deps.config.revision});
      } catch (e) {
        print('Health check failed: $e');
        return json({'status': 'database unavailable'}, status: 503);
      }
    });
  mountAuth(api, deps);
  mountPlaces(api, deps);
  mountRanking(api, deps);
  mountSocial(api, deps);
  mountModeration(api, deps);
  mountTesterRequests(api, deps);

  final root = Router()
    ..mount('/api/v1/', api.call)
    ..get('/', (Request request) => landingPage(request, english: false))
    ..get('/en', (Request request) => landingPage(request, english: true))
    ..get('/en/', (Request request) => landingPage(request, english: true))
    ..get('/i/<code>', (Request request, String code) => invitePage(deps, request, code))
    ..get('/b/<placeId>', (Request request, String placeId) => reviewLinkPage(deps, request, placeId))
    ..get('/aushang/<placeId>', (Request request, String placeId) => posterPage(deps, request, placeId))
    ..get('/datenschutz', privacyPage)
    ..get('/.well-known/apple-app-site-association', (Request _) => json(_appSiteAssociation))
    ..get('/.well-known/assetlinks.json', (Request _) => json(_assetLinks));

  final webDir = Directory(deps.config.webDir);
  if (webDir.existsSync()) {
    final static = createStaticHandler(webDir.path, defaultDocument: 'index.html');
    final index = File('${webDir.path}/index.html');
    // Unknown paths (e.g. /app, /login?token=…) fall back to the single-page app.
    Future<Response> spa(Request request) async {
      final response = await static(request);
      if (response.statusCode != 404 || request.method != 'GET') return response;
      return Response.ok(index.openRead(), headers: {'content-type': 'text/html; charset=utf-8'});
    }

    root.all('/<ignored|.*>', spa);
  }

  return const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(cors(deps.config.corsOrigin))
      .addMiddleware(errorHandling())
      .addHandler(root.call);
}
