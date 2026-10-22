import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// The service worker (`web/firebase-messaging-sw.js`) can't read the app's
/// storage, so it finds the device's fetch key and the API in the cache.
Future<void> shareWithServiceWorker(String key, String apiBase) async {
  final cache = await web.window.caches.open('doener-push').toDart;
  await cache.put('/push-key'.toJS, web.Response(jsonEncode({'key': key, 'api': apiBase}).toJS)).toDart;
}
