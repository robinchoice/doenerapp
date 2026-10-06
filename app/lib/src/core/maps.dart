import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

export 'maps_loader_stub.dart' if (dart.library.js_interop) 'maps_loader_web.dart';

/// Maps JavaScript API key for the web build (`--dart-define=GOOGLE_MAPS_WEB_KEY=…`).
/// iOS and Android get their keys from the native project configuration.
const mapsWebKey = String.fromEnvironment('GOOGLE_MAPS_WEB_KEY');

bool get mapsAvailable => !kIsWeb || mapsWebKey.isNotEmpty;

/// Hides shops and other businesses so only our pins stand out. On a dark
/// screen the map turns dark too, in the app's neutrals.
String mapStyle(Brightness brightness) => brightness == Brightness.dark ? _darkMapStyle : _lightMapStyle;

const _lightMapStyle = '[{"featureType":"poi.business","stylers":[{"visibility":"off"}]}]';

const _darkMapStyle = '['
    '{"featureType":"poi.business","stylers":[{"visibility":"off"}]},'
    '{"elementType":"geometry","stylers":[{"color":"#1c1b21"}]},'
    '{"elementType":"labels.text.fill","stylers":[{"color":"#9a98a3"}]},'
    '{"elementType":"labels.text.stroke","stylers":[{"color":"#0e0d12"}]},'
    '{"featureType":"road","elementType":"geometry","stylers":[{"color":"#2c2b33"}]},'
    '{"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#16151b"}]},'
    '{"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#3a3942"}]},'
    '{"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#1c261f"}]},'
    '{"featureType":"transit","elementType":"geometry","stylers":[{"color":"#24232a"}]},'
    '{"featureType":"water","elementType":"geometry","stylers":[{"color":"#172334"}]}'
    ']';

/// Pins in the app's tone instead of Google's orange.
const pinHue = 40.0;

/// Google requires attribution wherever Places data is shown without a Google map.
class GoogleAttribution extends StatelessWidget {
  const GoogleAttribution({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Ortsdaten: Google Maps',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.outline),
        ),
      );
}
