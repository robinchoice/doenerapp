import 'package:doener_models/doener_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:sembast/sembast.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'session.dart';

/// How long after a check-in the app asks how it was.
const reminderDelay = Duration(minutes: 30);

/// Title and text of the reminder. Whoever rated the place before is asked
/// whether the score still holds.
(String, String) reminderText(String placeName, double? rating) => rating == null
    ? ('Wie war’s bei $placeName?', 'Tipp hier und bewerte deinen Besuch.')
    : ('Bleibt’s bei ${rating.toStringAsFixed(1).replaceAll('.', ',')}?', 'Dein Besuch bei $placeName – passt deine Bewertung noch?');

/// Payload of a tapped local notification (a reminder or a push), until the
/// app has handled it.
final notificationTapped = ValueNotifier<String?>(null);

/// The plugin's tap callback. Every set-up passes this one, so a push that sets
/// the plugin up again in the background (push.dart) doesn't lose the taps.
void onNotificationTapped(NotificationResponse response) => notificationTapped.value = response.payload;

/// "Wie war's bei X?" half an hour after a check-in, as a local notification
/// on iOS and Android. Browsers can't schedule notifications; there the card
/// on Start does the asking ([AppData.toReview]), which the apps show as well.
class Reminders {
  /// A later check-in replaces the reminder of an earlier one.
  static const _id = 1;
  static const _enabledKey = 'checkInReminder';

  static bool get supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);

  final Database _db;
  final _plugin = FlutterLocalNotificationsPlugin();

  /// The place of a tapped reminder, until the app has opened its review.
  ValueNotifier<String?> get opened => notificationTapped;
  bool enabled = true;

  Reminders(this._db);

  Future<void> init() async {
    enabled = await settingsStore.record(_enabledKey).get(_db) as bool? ?? true;
    tz.initializeTimeZones();
    final zone = (await FlutterTimezone.getLocalTimezone()).identifier;
    tz.setLocalLocation(tz.timeZoneDatabase.locations[zone] ?? tz.UTC);
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // Asked for with the first check-in, not on start.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: onNotificationTapped,
    );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) opened.value = launch!.notificationResponse?.payload;
  }

  Future<void> schedule(PlaceDto place, DateTime visitedAt, {double? rating}) async {
    if (!enabled) return;
    await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, sound: true);
    await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    final (title, body) = reminderText(place.name, rating);
    await _plugin.zonedSchedule(
      id: _id,
      title: title,
      body: body,
      payload: place.placeId,
      scheduledDate: tz.TZDateTime.from(visitedAt.add(reminderDelay), tz.local),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails('check_in_reminder', 'Erinnerung nach dem Check-in'),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// Reviewed in the meantime: no need to ask any more.
  Future<void> cancelFor(String placeId) async {
    final pending = await _plugin.pendingNotificationRequests();
    if (pending.any((p) => p.id == _id && p.payload == placeId)) await _plugin.cancel(id: _id);
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    await settingsStore.record(_enabledKey).put(_db, value);
    if (!value) await _plugin.cancel(id: _id);
  }
}
