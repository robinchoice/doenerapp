import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_data.dart';
import '../../core/maps.dart';
import '../../ui/widgets.dart';

/// Searches all places the app knows. Pops the chosen place.
class PlaceSearchSheet extends StatefulWidget {
  const PlaceSearchSheet({super.key});

  @override
  State<PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends State<PlaceSearchSheet> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final places = query.isEmpty
        ? <PlaceDto>[]
        : (context.watch<AppData>().activePlaces.where((p) => p.name.toLowerCase().contains(query)).toList()
          ..sort((a, b) => a.name.compareTo(b.name)));

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        TextField(
          controller: _search,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(hintText: 'Döner-Laden suchen…', prefixIcon: Icon(Icons.search)),
        ),
        const SizedBox(height: 12),
        if (query.isNotEmpty && places.isEmpty)
          const EmptyState(
            icon: Icons.search_off,
            title: 'Nichts gefunden',
            message: 'Gesucht wird in allen Läden, die die App schon kennt. Schieb die Karte dorthin, wo du suchst, und zoom nah heran.',
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
                  if (p.avgRating != null)
                    ScoreBlock(average: p.avgRating!, count: p.reviewCount, size: 26),
                ],
              ),
            ),
          ),
        if (places.isNotEmpty) const GoogleAttribution(),
      ],
    );
  }
}
