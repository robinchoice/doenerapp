import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_data.dart';
import '../../core/maps.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';
import '../place/place_detail.dart';

enum _Sort { rating, visits, recent }

/// Places the user visited or reviewed.
class MyPlacesScreen extends StatefulWidget {
  const MyPlacesScreen({super.key});

  @override
  State<MyPlacesScreen> createState() => _MyPlacesScreenState();
}

class _MyPlacesScreenState extends State<MyPlacesScreen> {
  _Sort _sort = _Sort.rating;

  @override
  Widget build(BuildContext context) {
    final data = context.watch<AppData>();
    final diet = context.watch<Session>().diet;
    final ids = {...data.visits.map((v) => v.dto.placeId), ...data.reviews.keys};
    final places = [
      for (final id in ids)
        if (data.places[id] case final place?)
          (place: place, visits: data.visitsAt(id), rating: data.reviews[id]?.dto.headline(diet)),
    ];
    switch (_sort) {
      case _Sort.rating:
        places.sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0));
      case _Sort.visits:
        places.sort((a, b) => b.visits.length.compareTo(a.visits.length));
      case _Sort.recent:
        DateTime last(List<LocalVisit> v) => v.isEmpty ? DateTime(0) : v.first.dto.visitedAt;
        places.sort((a, b) => last(b.visits).compareTo(last(a.visits)));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Meine Läden')),
      body: places.isEmpty
          ? const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'Noch keine Läden',
              message: 'Hier landen alle Läden, in denen du eingecheckt oder die du bewertet hast.',
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SegmentedButton<_Sort>(
                  segments: const [
                    ButtonSegment(value: _Sort.rating, label: Text('Bewertung')),
                    ButtonSegment(value: _Sort.visits, label: Text('Besuche')),
                    ButtonSegment(value: _Sort.recent, label: Text('Zuletzt')),
                  ],
                  selected: {_sort},
                  onSelectionChanged: (s) => setState(() => _sort = s.first),
                ),
                const SizedBox(height: 16),
                for (final p in places)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GlassCard(
                      onTap: () => showPlaceDetail(context, p.place),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(p.place.name, style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 4),
                                Row(children: [
                                  if (p.visits.isNotEmpty) ...[
                                    const Icon(Icons.check_circle, size: 14, color: Colors.green),
                                    Text(' ${p.visits.length}   '),
                                  ],
                                  if (p.rating != null) DoenerRating(value: p.rating!, size: 12),
                                ]),
                              ],
                            ),
                          ),
                          if (p.place.city != null)
                            Text(p.place.city!, style: TextStyle(color: Theme.of(context).colorScheme.outline, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                const GoogleAttribution(),
              ],
            ),
    );
  }
}
