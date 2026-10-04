import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_data.dart';
import '../../core/maps.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';
import '../place/place_detail.dart';

/// Own check-ins and reviews; entries the server hasn't confirmed yet are marked.
class MyActivityScreen extends StatelessWidget {
  const MyActivityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final data = context.watch<AppData>();
    final diet = context.watch<Session>().diet;
    final entries = [
      for (final v in data.visits)
        (type: FeedItemType.visit, placeId: v.dto.placeId, placeName: v.dto.placeName, at: v.dto.visitedAt, text: null as String?, score: null as double?, ratings: const <RatingItem, int>{}, food: v.dto.foodType, pending: v.pending),
      for (final r in data.reviews.values)
        (type: FeedItemType.review, placeId: r.dto.placeId, placeName: r.dto.placeName, at: r.dto.updatedAt, text: r.dto.text, score: r.dto.headline(diet), ratings: r.dto.ratings, food: null as String?, pending: r.pending),
    ]..sort((a, b) => b.at.compareTo(a.at));

    return Scaffold(
      appBar: AppBar(title: const Text('Meine Aktivität')),
      body: entries.isEmpty
          ? const EmptyState(
              icon: Icons.restaurant,
              title: 'Noch keine Aktivität',
              message: 'Checke bei einem Döner-Laden ein oder schreibe eine Bewertung.',
            )
          : RefreshIndicator(
              onRefresh: () async {
                await data.sync();
                await data.refreshMine();
              },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final e in entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: ActivityCard(
                        type: e.type,
                        title: e.type == FeedItemType.visit ? 'Eingecheckt' : 'Bewertet',
                        subtitle: e.placeName,
                        timestamp: e.at,
                        score: e.score,
                        ratings: e.ratings,
                        diet: diet,
                        text: e.text,
                        foodType: e.food,
                        pending: e.pending,
                        onTap: data.places[e.placeId] == null ? null : () => showPlaceDetail(context, data.places[e.placeId]!),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

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
          (place: place, visits: data.visitsAt(id), rating: data.reviews[id]?.dto.headline(diet)?.round()),
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
