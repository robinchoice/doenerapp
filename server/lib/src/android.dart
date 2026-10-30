import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'deps.dart';
import 'http.dart';

/// Without Play, Android testers install the APK that `mobile.yml` puts into
/// this GitHub release for every release tag (README, „Android-App“).
const apkReleaseUrl = 'https://github.com/robinchoice/doenerapp/releases/download/android-latest';

const _cacheFor = Duration(minutes: 10);
var _cachedBuild = (build: null as int?, until: DateTime(0));

/// `/android` on the landing page: the latest APK.
Response apkDownload(Request _) => Response.found('$apkReleaseUrl/doener.apk');

/// GET /android {build, url} — the build number of the latest APK, so the
/// app can offer it. `build` is null while GitHub can't tell.
void mountAndroid(Router router, Deps deps) {
  router.get('/android', (Request request) async {
    if (DateTime.now().isAfter(_cachedBuild.until)) {
      int? build;
      try {
        final response = await deps.httpClient.get(Uri.parse('$apkReleaseUrl/version.json'));
        if (response.statusCode == 200) build = (jsonDecode(response.body) as Map<String, dynamic>)['build'] as int?;
      } catch (e) {
        print('APK version check failed: $e');
      }
      _cachedBuild = (build: build, until: DateTime.now().add(_cacheFor));
    }
    return json({'build': _cachedBuild.build, 'url': '${deps.config.publicBase(request.requestedUri)}/android'});
  });
}
