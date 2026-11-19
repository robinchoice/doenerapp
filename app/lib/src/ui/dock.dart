import 'dart:convert';
import 'dart:math' as math;

import 'dock_fetch.dart' if (dart.library.js_interop) 'dock_fetch_web.dart';

// The public list shared by the Pleasance family.
const pleasanceAppsUrl = 'https://pleasance.org/apps.json';

class PleasanceApp {
  final String name;
  final Uri url;
  final double from;
  final double to;
  // Apps whose page is a download rather than the app itself
  final bool desktop;
  // SVG source of the tile, null if it did not load
  final String? icon;

  const PleasanceApp({
    required this.name,
    required this.url,
    required this.from,
    required this.to,
    this.desktop = false,
    this.icon,
  });

  double get middle => (from + to) / 2;
}

/// Only web links and valid band positions may enter the app dock.
List<({PleasanceApp app, Uri icon})> parsePleasanceApps(Object? json) {
  Uri web(Object? value) {
    final uri = value is String ? Uri.tryParse(value) : null;
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http') || uri.host.isEmpty) {
      throw FormatException('not a web link: $value');
    }
    return uri;
  }

  double stage(Object? value) {
    if (value is num && value >= 1 && value <= 7) return value.toDouble();
    throw FormatException('not a place on the band: $value');
  }

  final apps = json is Map ? json['apps'] : null;
  if (apps is! List) throw const FormatException('no apps');
  return [
    for (final entry in apps)
      if (entry case {'name': final String name, 'band': {'from': final from, 'to': final to}}
          when name.isNotEmpty && name.length <= 40)
        (
          app: PleasanceApp(
            name: name,
            url: web(entry['url']),
            from: stage(from),
            to: stage(to),
            desktop: entry['desktop'] == true,
          ),
          icon: web(entry['icon']),
        )
      else
        throw FormatException('not an app: $entry'),
  ];
}

/// The public family list and its tiles, loaded only when the dock is opened.
Future<List<PleasanceApp>> loadPleasanceApps() async {
  final entries = parsePleasanceApps(jsonDecode(await fetchDockText(Uri.parse(pleasanceAppsUrl))));
  return Future.wait([for (final entry in entries) () async {
    String? icon;
    try { icon = await fetchDockText(entry.icon); } catch (_) { /* The tile keeps its placeholder. */ }
    return PleasanceApp(name: entry.app.name, url: entry.app.url, from: entry.app.from, to: entry.app.to,
      desktop: entry.app.desktop, icon: icon);
  }()]);
}

/// A place in the dock: an app, or a free spot (app null) on a place of the band.
typedef DockSlot = ({PleasanceApp? app, int stage});

/// Seven places in band order. A place holds the apps whose section centres on
/// it, a place without one shows as a free spot.
List<DockSlot> dockSlots(List<PleasanceApp> apps) => [
  for (var stage = 1; stage <= 7; stage++)
    ...() {
      final here = apps.where((app) => app.middle.round() == stage).toList()
        ..sort((a, b) => a.middle.compareTo(b.middle));
      return here.isEmpty ? [(app: null, stage: stage)] : [for (final app in here) (app: app, stage: stage)];
    }(),
];

/// Icons grow the closer the finger gets, their
/// neighbours make room, and the spot under the finger stays under it.
/// Returns left edge and size of every icon.
List<({double left, double size})> dockLayout({
  required List<double> sizes,
  required double gap,
  required double grow,
  required double reach,
  required double center,
  required double? pointer,
  required double min,
  required double max,
}) {
  double clamp(double value, double low, double high) => math.max(low, math.min(high, value));
  final unit = sizes.reduce(math.max) + gap;
  final restWidth = sizes.fold(0.0, (a, b) => a + b) + gap * (sizes.length - 1);
  final restLeft = clamp(center - restWidth / 2, min, max - restWidth);
  final centers = <double>[];
  var x = restLeft;
  for (final size in sizes) {
    centers.add(x + size / 2);
    x += size + gap;
  }
  final grown = [
    for (var i = 0; i < sizes.length; i++)
      if (pointer == null) sizes[i] else sizes[i] * (1 + grow * _closeness((pointer - centers[i]).abs() / unit, reach)),
  ];
  final width = grown.fold(0.0, (a, b) => a + b) + gap * (grown.length - 1);
  final share = pointer == null ? 0.5 : clamp((pointer - restLeft) / restWidth, 0, 1);
  final anchor = pointer ?? restLeft + restWidth / 2;
  x = clamp(anchor - share * width, min, max - width);
  final slots = <({double left, double size})>[];
  for (final size in grown) {
    slots.add((left: x, size: size));
    x += size + gap;
  }
  return slots;
}

double _closeness(double distance, double reach) =>
    distance >= reach ? 0 : (math.cos(distance / reach * math.pi) + 1) / 2;
