import 'package:shelf/shelf.dart';

import 'deps.dart';
import 'http.dart';

/// The app sends its platform and build number. Below the minimum from the
/// env every API call but feedback gets 426 with where to update, and the app
/// shows only its update screen (README, „Update-Pflicht“). The web app and
/// local builds send nothing and are never blocked.
Middleware requireMinimumBuild(Deps deps) => (inner) => (request) {
      final platform = request.headers['x-app-platform'];
      final minimum = switch (platform) {
        'ios' => deps.config.minBuildIos,
        'android' => deps.config.minBuildAndroid,
        _ => 0,
      };
      final build = int.tryParse(request.headers['x-app-build'] ?? '') ?? 0;
      if (build <= 0 || build >= minimum || request.url.path == 'feedback') return inner(request);
      final publicUrl = deps.config.publicBase(request.requestedUri);
      return json({
        'error': 'Diese Version der App ist zu alt. Bitte aktualisiere sie.',
        'code': 'UPDATE_REQUIRED',
        'url': platform == 'ios' ? deps.config.appDownloadUrl : '$publicUrl/android',
      }, status: 426);
    };
