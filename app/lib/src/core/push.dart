import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:doener_models/doener_models.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:http/http.dart' as http;

import 'push_worker_stub.dart' if (dart.library.js_interop) 'push_worker_web.dart';
import 'reminders.dart';
import 'session.dart';

/// The platform's Firebase API key from the build (`--dart-define=FIREBASE_API_KEY=…`).
/// Without it (local builds, tests) there is no push.
const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');

FirebaseOptions get _options => FirebaseOptions(
      apiKey: _apiKey,
      appId: kIsWeb
          ? '1:26724390514:web:d8f8f2970f78702d3d54eb'
          : defaultTargetPlatform == TargetPlatform.iOS
              ? '1:26724390514:ios:4bd619fdcbeac6753d54eb'
              : '1:26724390514:android:323975eaff927a8a3d54eb',
      messagingSenderId: '26724390514',
      projectId: 'doener-app-510118',
      iosBundleId: 'com.robinchoice.doener',
    );

String get _platform => kIsWeb ? 'web' : defaultTargetPlatform.name;

/// Payload of a notification shown for a push: `push:<type>:<event ID>:<shop ID>`,
/// the shop may be empty. Builds before the bell left out type and event.
const pushPayloadPrefix = 'push:';

/// The type and event of a push payload, null for old ones.
(String type, String id)? pushEventOf(String payload) {
  final parts = payload.substring(pushPayloadPrefix.length).split(':');
  return parts.length < 3 ? null : (parts[0], parts[1]);
}

/// The shop of a push payload, if it has one.
String? pushPlaceOf(String payload) {
  final parts = payload.substring(pushPayloadPrefix.length).split(':');
  final place = parts.length < 3 ? parts.first : parts[2];
  return place.isEmpty ? null : place;
}

/// The device's key for what its pushes are about (`/push-events/<id>`) and
/// the API it belongs to. Apart from the session and readable after the first
/// unlock, so a push to a locked iPhone still gets its details.
const _storage = FlutterSecureStorage(iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock));
const _keyName = 'push_fetch_key';
const _apiName = 'push_api_base';

/// What push [id] is about, fetched with the device's key; null when that
/// fails (offline, locked out, older than a week).
Future<PushEventDto?> fetchPushEvent(String id) async {
  try {
    final key = await _storage.read(key: _keyName);
    final api = await _storage.read(key: _apiName);
    if (key == null || api == null) return null;
    final response =
        await http.get(Uri.parse('$api/push-events/$id'), headers: {'authorization': 'Push $key'}).timeout(const Duration(seconds: 10));
    return response.statusCode == 200 ? PushEventDto.fromJson(jsonDecode(response.body) as Map<String, dynamic>) : null;
  } catch (_) {
    return null;
  }
}

/// Turns a signal (event type and ID) into a notification: the text comes
/// from the server, and without it the notification only names the type.
/// The same event again (friends checking in close together) replaces it.
/// Runs in the background isolate as well, which has to set up the plugin.
Future<void> showPushSignal(RemoteMessage message, {bool setUp = false}) async {
  final type = message.data['type'] as String?;
  final id = message.data['id'] as String?;
  if (type == null || id == null) return;
  final event = await fetchPushEvent(id);
  final (title, body) = event == null ? neutralPushText(type) : (event.title, event.body);
  final plugin = FlutterLocalNotificationsPlugin();
  if (setUp) await plugin.initialize(settings: notificationSettings, onDidReceiveNotificationResponse: onNotificationTapped);
  await plugin.show(
    id: id.hashCode & 0x7fffffff,
    title: title,
    body: body,
    payload: '$pushPayloadPrefix$type:$id:${event?.placeId ?? ''}',
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'push',
        'Freunde und neue Läden',
        importance: Importance.high,
        priority: Priority.high,
        actions: [AndroidNotificationAction(lessAction, 'Weniger davon', showsUserInterface: true)],
      ),
      iOS: DarwinNotificationDetails(categoryIdentifier: 'push'),
    ),
  );
}

/// Signals while the app is in the background or closed. Android wakes it for
/// each; iOS only when it decides to (not after the app was swiped away).
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) => showPushSignal(message, setUp: true);

/// Pushes through Firebase Cloud Messaging: friends' check-ins and new shops.
/// The server decides who gets what and sends only signals; the app fetches
/// the text and shows the notification itself (on the web the service worker,
/// `web/firebase-messaging-sw.js`).
class Push {
  static bool get supported => _apiKey.isNotEmpty;

  /// The shop of a tapped push, until the home screen opens it.
  final opened = ValueNotifier<String?>(null);

  /// Type and event of a push whose "Weniger davon" was tapped, until the
  /// home screen asks what to leave out.
  final less = ValueNotifier<(String type, String id)?>(null);
  String? _token;
  StreamSubscription<String>? _refresh;

  Future<void> init() async {
    await Firebase.initializeApp(options: _options);
    if (kIsWeb) return;
    FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
    // In the foreground the app shows them itself, with the plugin the
    // reminders have set up already.
    FirebaseMessaging.onMessage.listen((message) => showPushSignal(message).catchError((_) {}));
  }

  /// Asks for permission (once; browsers only on a tap, see [ask]) and gives
  /// the server this device's token and fetch key, with the position for the
  /// user's city and the time zone for the quiet hours.
  Future<void> register(Session session, {double? latitude, double? longitude, bool ask = true}) async {
    final messaging = FirebaseMessaging.instance;
    final settings = ask ? await messaging.requestPermission() : await messaging.getNotificationSettings();
    if (settings.authorizationStatus != AuthorizationStatus.authorized &&
        settings.authorizationStatus != AuthorizationStatus.provisional) {
      return;
    }
    // The newer register()/onRegistered hand out installation IDs, which the
    // server's FCM HTTP v1 sender doesn't take; tokens still work everywhere.
    // ignore: deprecated_member_use
    final token = await messaging.getToken();
    if (token == null) return;
    final key = await _fetchKey(session.apiBase);
    String? zone;
    try {
      zone = (await FlutterTimezone.getLocalTimezone()).identifier;
    } catch (_) {
      // The server then counts the quiet hours in German time.
    }
    Future<void> send(String token) async {
      _token = token;
      await session.api.put(
        '/me/push-token',
        PushTokenRequest(token: token, platform: _platform, latitude: latitude, longitude: longitude, fetchKey: key, timeZone: zone)
            .toJson(),
      );
    }

    await send(token);
    // ignore: deprecated_member_use
    _refresh ??= messaging.onTokenRefresh.listen((token) => send(token).catchError((_) {}));
  }

  /// Made once per device; stays when someone else signs in there.
  Future<String> _fetchKey(String apiBase) async {
    var key = await _storage.read(key: _keyName);
    if (key == null) {
      final random = Random.secure();
      key = base64Url.encode(List<int>.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
      await _storage.write(key: _keyName, value: key);
    }
    await _storage.write(key: _apiName, value: apiBase);
    // Without it the browser shows the neutral text, push still works.
    await shareWithServiceWorker(key, apiBase).catchError((_) {});
    return key;
  }

  /// Before logging out: this device no longer belongs to the account.
  Future<void> unregister(Session session) async {
    final token = _token;
    if (token == null) return;
    _token = null;
    try {
      await session.api.delete('/me/push-tokens/${Uri.encodeComponent(token)}');
    } catch (_) {
      // Offline: the token moves to whoever signs in next on this device.
    }
  }
}
