import 'dart:async';

import 'package:doener_models/doener_models.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

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

/// Pushes through Firebase Cloud Messaging: friends' check-ins and new shops.
/// The server decides who gets what; the app only hands it its token.
class Push {
  static bool get supported => _apiKey.isNotEmpty;

  /// The shop of a tapped push, until the home screen opens it.
  final opened = ValueNotifier<String?>(null);
  String? _token;
  StreamSubscription<String>? _refresh;

  Future<void> init() async {
    await Firebase.initializeApp(options: _options);
    // iOS shows pushes while the app is open only when asked to.
    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(alert: true, sound: true);
    FirebaseMessaging.onMessageOpenedApp.listen(_open);
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _open(initial);
  }

  void _open(RemoteMessage message) => opened.value = message.data['placeId'] as String?;

  /// Asks for permission (once; browsers only on a tap, see [ask]) and gives
  /// the server this device's token, with the position for the user's city.
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
    Future<void> send(String token) async {
      _token = token;
      await session.api.put(
        '/me/push-token',
        PushTokenRequest(token: token, platform: _platform, latitude: latitude, longitude: longitude).toJson(),
      );
    }

    await send(token);
    // ignore: deprecated_member_use
    _refresh ??= messaging.onTokenRefresh.listen((token) => send(token).catchError((_) {}));
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
