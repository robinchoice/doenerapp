import 'dart:async';

import 'package:doener_models/doener_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/app_data.dart';
import '../../core/location.dart';
import '../../core/maps.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';
import '../place/place_detail.dart';
import 'map_pins.dart';
import 'place_search_sheet.dart';
import 'report_shop_sheet.dart';

/// Above this span the viewport would be dot-soup; we don't load places.
const _maxFetchSpanDeg = 0.5;

/// Names of rated places from this zoom on, further out they'd overlap.
const _namesFromZoom = 15.0;

/// Whether people found food for [diet] at [place]. Unknown places stay on
/// the map, faded — most places aren't rated that far yet.
bool _knownToFit(PlaceDto place, Diet diet) => switch (diet) {
      Diet.all => true,
      Diet.vegetarian => place.vegetarianCount > 0 || place.veganCount > 0 || place.veganOptions == true,
      Diet.vegan => place.veganCount > 0 || place.veganOptions == true,
    };

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? _controller;
  LatLng _center = fallbackLocation;
  LatLngBounds? _loadedBounds;
  LatLngBounds? _visible;
  bool _zoomIn = false;
  bool _loading = false;
  String? _error;
  bool _favoritesOnly = false;
  bool _centeredOnUser = false;
  bool _showNames = false;
  final _pins = <String, MapPin>{};
  final _drawing = <String>{};
  // Last pin per place, shown while its new look is being drawn
  final _shown = <String, MapPin>{};

  /// Draws the pins missing in [specs] off the build and shows them together.
  Future<void> _drawPins(Map<String, Future<MapPin> Function()> specs) async {
    _drawing.addAll(specs.keys);
    final pins = await Future.wait(specs.values.map((draw) => draw()));
    if (!mounted) return;
    setState(() {
      for (final (i, key) in specs.keys.indexed) {
        _pins[key] = pins[i];
      }
    });
  }

  Future<void> _search() async {
    final place = await showAppSheet<PlaceDto>(context, (_) => const PlaceSearchSheet());
    if (place == null || !mounted) return;
    _controller?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(place.latitude, place.longitude), 16));
    await showPlaceDetail(context, place);
  }

  Future<void> _load({bool force = false}) async {
    final bounds = await _controller?.getVisibleRegion();
    if (bounds == null || !mounted) return;
    final (south, west, north, east) =
        (bounds.southwest.latitude, bounds.southwest.longitude, bounds.northeast.latitude, bounds.northeast.longitude);
    // The server only searches Google for small areas. Bigger ones show known
    // places and don't count as loaded, so zooming in there searches.
    final searchable = tilesCovering(minLat: south, minLon: west, maxLat: north, maxLon: east).length <= maxTilesPerRequest;
    setState(() {
      _visible = bounds;
      _zoomIn = !searchable;
    });
    if (north - south > _maxFetchSpanDeg || east - west > _maxFetchSpanDeg) return;
    final loaded = _loadedBounds;
    if (!force && loaded != null && loaded.contains(bounds.southwest) && loaded.contains(bounds.northeast)) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await context.read<AppData>().loadArea(south: south, west: west, north: north, east: east);
      if (searchable) _loadedBounds = bounds;
    } on OfflineException catch (e) {
      _error = e.toString();
    } on ApiException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = context.watch<AppData>();
    final diet = context.watch<Session>().diet;
    final userPosition = context.watch<LocationService>().position;

    if (userPosition != null && !_centeredOnUser && _controller != null) {
      _centeredOnUser = true;
      _controller!.moveCamera(CameraUpdate.newLatLngZoom(userPosition, 15));
    }

    final visitCounts = <String, int>{};
    for (final v in data.visits) {
      visitCounts[v.dto.placeId] = (visitCounts[v.dto.placeId] ?? 0) + 1;
    }
    final places = data.activePlaces
        .where((p) => !_favoritesOnly || data.favorites.contains(p.placeId))
        .where((p) => diet != Diet.vegan || p.veganOptions != false)
        .toList();
    final brightness = Theme.of(context).brightness;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final missing = <String, Future<MapPin> Function()>{};
    MapPin? pinFor(PlaceDto place) {
      final color = data.favorites.contains(place.placeId)
          ? favoritePinColor
          : (visitCounts[place.placeId] ?? 0) > 0
              ? visitedPinColor
              : placePinColor;
      final average = place.score(diet).average;
      final score = average == null ? null : formatRating(average);
      final name = score != null && _showNames ? place.name : null;
      final key = '${color.toARGB32()}|$brightness|$score|$name';
      final pin = _pins[key];
      if (pin == null && !_drawing.contains(key)) {
        missing[key] = () => drawPin(color: color, brightness: brightness, pixelRatio: pixelRatio, score: score, name: name);
      }
      return pin;
    }

    final markers = <Marker>{};
    for (final place in places) {
      final pin = pinFor(place) ?? _shown[place.placeId];
      if (pin == null) continue;
      _shown[place.placeId] = pin;
      markers.add(Marker(
        markerId: MarkerId(place.placeId),
        position: LatLng(place.latitude, place.longitude),
        icon: pin.icon,
        anchor: pin.anchor,
        // Better places and favourites on top where pins overlap
        zIndexInt: (data.favorites.contains(place.placeId) ? 100 : 0) + ((place.score(diet).average ?? 0) * 10).round(),
        alpha: _knownToFit(place, diet) ? 1 : 0.4,
        onTap: () => showPlaceDetail(context, place),
      ));
    }
    if (missing.isNotEmpty) _drawPins(missing);
    final visible = places.where((p) => _visible?.contains(LatLng(p.latitude, p.longitude)) ?? true).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Döner Karte'),
        leading: IconButton(
          tooltip: 'Fehlenden Laden melden',
          icon: const Icon(Icons.add_location_alt_outlined),
          onPressed: () => showAppSheet(context, (_) => ReportShopSheet(position: _center)),
        ),
        actions: [
          if (!mapsAvailable) IconButton(tooltip: 'Laden suchen', icon: const Icon(Icons.search), onPressed: _search),
          IconButton(
            tooltip: 'Nur Favoriten',
            icon: Icon(_favoritesOnly ? Icons.favorite : Icons.favorite_border, color: _favoritesOnly ? Colors.pink : null),
            onPressed: () => setState(() => _favoritesOnly = !_favoritesOnly),
          ),
        ],
      ),
      body: !mapsAvailable
          ? const EmptyState(
              icon: Icons.map_outlined,
              title: 'Karte nicht verfügbar',
              message: 'Für die Web-Version ist kein Google-Maps-Key hinterlegt.',
            )
          : Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(target: userPosition ?? fallbackLocation, zoom: 14),
                  style: mapStyle(Theme.of(context).brightness),
                  myLocationEnabled: userPosition != null,
                  myLocationButtonEnabled: false,
                  mapToolbarEnabled: false,
                  zoomControlsEnabled: kIsWeb,
                  onMapCreated: (controller) {
                    _controller = controller;
                    _load();
                  },
                  onCameraMove: (position) {
                    _center = position.target;
                    final showNames = position.zoom >= _namesFromZoom;
                    if (showNames != _showNames) setState(() => _showNames = showNames);
                  },
                  onCameraIdle: _load,
                  markers: markers,
                ),
                // On the web the map is a DOM element that still takes the touches under an
                // open sheet. The browser then cancels the sheet's scrolling.
                if (kIsWeb && ModalRoute.isCurrentOf(context) == false)
                  Positioned.fill(child: PointerInterceptor(child: const SizedBox.expand())),
                // Testers missed the search behind the icon in the app bar
                Positioned(
                  top: 8,
                  left: 16,
                  right: 16,
                  child: Center(
                    child: Pill(
                      onTap: _search,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.search, size: 18, color: context.accent),
                        const SizedBox(width: 8),
                        const Text('Laden suchen', style: TextStyle(fontWeight: FontWeight.w600)),
                        if (visible > 0)
                          Flexible(
                            child: Text(
                              ' · $visible auf der Karte',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ),
                          ),
                      ]),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 24,
                  left: 16,
                  right: 80,
                  child: Center(
                    child: _loading
                        ? const Pill(
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                              SizedBox(width: 8),
                              Text('Lade Döner-Läden…'),
                            ]),
                          )
                        : _error != null
                            ? Pill(
                                onTap: () => _load(force: true),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Icon(Icons.warning_amber, color: Theme.of(context).colorScheme.error, size: 18),
                                  const SizedBox(width: 6),
                                  Flexible(child: Text(_error!, overflow: TextOverflow.ellipsis)),
                                  const SizedBox(width: 6),
                                  Icon(Icons.refresh, size: 18, color: context.accent),
                                ]),
                              )
                            : _zoomIn
                                ? Pill(
                                    onTap: () => _controller?.animateCamera(CameraUpdate.zoomIn()),
                                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                                      Icon(Icons.zoom_in, size: 18, color: context.accent),
                                      const SizedBox(width: 6),
                                      const Flexible(child: Text('Für mehr Läden näher heranzoomen', overflow: TextOverflow.ellipsis)),
                                    ]),
                                  )
                                : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
      floatingActionButton: !mapsAvailable
          ? null
          : FloatingActionButton.small(
              tooltip: 'Mein Standort',
              onPressed: () async {
                final location = context.read<LocationService>();
                await location.request();
                final position = location.position;
                if (position != null) {
                  _controller?.animateCamera(CameraUpdate.newLatLngZoom(position, 15));
                } else if (context.mounted) {
                  showMessage(context, 'Standort nicht verfügbar');
                }
              },
              child: const Icon(Icons.my_location),
            ),
    );
  }
}
