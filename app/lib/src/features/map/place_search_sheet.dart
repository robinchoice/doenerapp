import 'dart:async';

import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/app_data.dart';
import '../../core/location.dart';
import '../../core/maps.dart';
import '../../ui/widgets.dart';

/// Searches the shops on the device and every shop the server knows, nearest
/// first. Pops the chosen place.
class PlaceSearchSheet extends StatefulWidget {
  const PlaceSearchSheet({super.key});

  @override
  State<PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends State<PlaceSearchSheet> {
  final _search = TextEditingController();
  Timer? _debounce;
  bool _searching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _changed() {
    setState(() {});
    _debounce?.cancel();
    final query = _search.text.trim();
    if (query.length < 2) return;
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      setState(() => _searching = true);
      final position = context.read<LocationService>().position;
      try {
        // The results land in the app's places, the list below shows them.
        await context.read<AppData>().searchPlaces(query, lat: position?.latitude, lon: position?.longitude);
      } on OfflineException {
        // The shops on the device are still found.
      } on ApiException {
        // Same.
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final position = context.watch<LocationService>().position;
    double distance(PlaceDto p) =>
        Geolocator.distanceBetween(position!.latitude, position.longitude, p.latitude, p.longitude);
    final places = query.isEmpty
        ? <PlaceDto>[]
        : (context.watch<AppData>().activePlaces.where((p) => p.name.toLowerCase().contains(query)).toList()
          ..sort(position == null ? (a, b) => a.name.compareTo(b.name) : (a, b) => distance(a).compareTo(distance(b))));

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        TextField(
          controller: _search,
          autofocus: true,
          onChanged: (_) => _changed(),
          decoration: const InputDecoration(hintText: 'Döner-Laden suchen…', prefixIcon: Icon(Icons.search)),
        ),
        const SizedBox(height: 12),
        if (query.isNotEmpty && places.isEmpty)
          _searching
              ? const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
              : const EmptyState(
                  icon: Icons.search_off,
                  title: 'Nichts gefunden',
                  message: 'Kein Döner-Laden mit diesem Namen bekannt. Schieb die Karte dorthin, wo du suchst, und zoom nah heran.',
                ),
        for (final p in places.take(30))
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GlassCard(
              onTap: () => Navigator.of(context).pop(p),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        if (p.city != null) Text(p.city!, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  if (p.avgRating != null) ScoreBlock(average: p.avgRating!, count: p.reviewCount, size: 26),
                ],
              ),
            ),
          ),
        if (places.isNotEmpty) const GoogleAttribution(),
      ],
    );
  }
}
