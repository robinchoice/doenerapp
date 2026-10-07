import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'auth.dart';
import 'deps.dart';
import 'http.dart';
import 'places.dart';
import 'privacy.dart';
import 'ranking.dart';
import 'social.dart';

/// Lets iOS open invite links in the installed app instead of the browser (Universal Links).
const _appSiteAssociation = {
  'applinks': {
    'details': [
      {
        'appIDs': ['T2F442364K.com.robinchoice.doener'],
        'components': [
          {'/': '/i/*'},
        ],
      },
    ],
  },
};

/// API under `/api/v1`, the Flutter web build (if present) everywhere else.
Handler buildHandler(Deps deps) {
  final api = Router(notFoundHandler: (_) => json({'error': 'Nicht gefunden'}, status: 404))
    ..get('/health', (Request _) async {
      try {
        await deps.db.execute('SELECT 1');
        return json({'status': 'ok'});
      } catch (e) {
        print('Health check failed: $e');
        return json({'status': 'database unavailable'}, status: 503);
      }
    });
  mountAuth(api, deps);
  mountPlaces(api, deps);
  mountRanking(api, deps);
  mountSocial(api, deps);

  final root = Router()
    ..mount('/api/v1/', api.call)
    ..get('/i/<code>', (Request request, String code) => invitePage(deps, request, code))
    ..get('/datenschutz', privacyPage)
    ..get('/.well-known/apple-app-site-association', (Request _) => json(_appSiteAssociation));

  final webDir = Directory(deps.config.webDir);
  if (webDir.existsSync()) {
    final static = createStaticHandler(webDir.path, defaultDocument: 'index.html');
    final index = File('${webDir.path}/index.html');
    // Unknown paths (e.g. /login?token=…) fall back to the single-page app.
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
