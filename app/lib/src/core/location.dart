import 'dart:async';

import 'package:doener_models/doener_models.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Freiburg — used until (or unless) the user shares their location.
const fallbackLocation = LatLng(47.999, 7.842);

class LocationService extends ChangeNotifier {
  LatLng? position;
  bool denied = false;
  StreamSubscription<Position>? _updates;

  /// A city the user looks around in instead of their own area, until the
  /// app restarts. Check-ins always go by [position].
  CityDto? visiting;

  /// Where Start and Ranking show places for.
  LatLng get center =>
      visiting == null ? position ?? fallbackLocation : LatLng(visiting!.latitude, visiting!.longitude);

  void visit(CityDto? city) {
    visiting = city;
    notifyListeners();
  }

  /// With [ask] false (e.g. when the app comes back to the foreground) only
  /// an already granted location is used. Once it is followed, the position
  /// updates come from [_follow].
  Future<void> request({bool ask = true}) async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        if (!ask) return;
        permission = await Geolocator.requestPermission();
      }
      denied = permission == LocationPermission.denied || permission == LocationPermission.deniedForever;
      if (!denied && _updates == null) {
        // Timeout on the Dart side: the web plugin passes timeLimit in the wrong unit.
        final p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
        ).timeout(const Duration(seconds: 15));
        position = LatLng(p.latitude, p.longitude);
        _follow();
      }
    } catch (e) {
      // Location services off, timeout, or unsupported browser.
      debugPrint('Location unavailable: $e');
    }
    notifyListeners();
  }

  /// Keeps [position] current while the app is open, so the check-in button
  /// turns orange on arrival at a shop and grey again after leaving.
  void _follow() {
    _updates ??= Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, distanceFilter: 25),
    ).listen(
      (p) {
        position = LatLng(p.latitude, p.longitude);
        notifyListeners();
      },
      onError: (Object e) {
        // Services switched off: the next request() starts over.
        debugPrint('Location updates stopped: $e');
        _updates?.cancel();
        _updates = null;
      },
    );
  }

  @override
  void dispose() {
    _updates?.cancel();
    super.dispose();
  }
}
