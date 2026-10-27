import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sembast/sembast.dart';

import 'session.dart';

enum HapticLevel {
  off('Aus'),
  light('Leicht'),
  strong('Stark');

  final String label;
  const HapticLevel(this.label);
}

/// Vibration on rating taps and finished actions. The phone's own haptics
/// setting still applies on top.
class Haptics {
  static final _record = settingsStore.record('haptics');

  static bool get supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);

  static HapticLevel level = HapticLevel.light;

  static Future<void> load(Database db) async =>
      level = HapticLevel.values.asNameMap()[await _record.get(db)] ?? HapticLevel.light;

  static Future<void> setLevel(Database db, HapticLevel value) async {
    level = value;
    await _record.put(db, value.name);
    await success();
  }

  /// A tap on a rating.
  static Future<void> tick() => switch (level) {
        HapticLevel.off => Future.value(),
        HapticLevel.light => HapticFeedback.selectionClick(),
        HapticLevel.strong => HapticFeedback.lightImpact(),
      };

  /// A review saved, a friend added.
  static Future<void> success() async {
    switch (level) {
      case HapticLevel.off:
        return;
      case HapticLevel.light:
        await HapticFeedback.lightImpact();
      case HapticLevel.strong:
        await HapticFeedback.mediumImpact();
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await HapticFeedback.heavyImpact();
    }
  }
}
