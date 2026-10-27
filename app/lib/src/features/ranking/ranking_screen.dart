import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';

import '../../core/app_data.dart';
import '../../core/location.dart';
import '../../core/maps.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';
import '../place/place_detail.dart';
import 'best_of.dart';
import 'city_picker.dart';
import 'rating_info.dart';

/// Price filters in cents, null for any price.
const _maxPrices = [null, 600, 700, 800];

/// Moving further than this can mean another city.
const _reloadDistance = 1000.0;

/// The best places of the user's city: by the main score of the user's diet
/// or by a single dish.
class RankingScreen extends StatefulWidget {
  const RankingScreen({super.key});

  @override
  State<RankingScreen> createState() => _RankingScreenState();
}

class _RankingScreenState extends State<RankingScreen> {
  RankBy? _by;
  Diet? _diet;
  Future<RankingDto>? _ranking;
  LatLng? _center;
  String? _visiting;
  int? _maxPrice;
  Ingredient? _ingredient;

  void _load() {
    final location = context.read<LocationService>();
    final center = _center = location.center;
    _visiting = location.visiting?.name;
    _ranking = context
        .read<AppData>()
        .ranking(center.latitude, center.longitude, _by!, city: location.visiting?.name, maxPrice: _maxPrice, ingredient: _ingredient);
  }

  Future<void> _pickIngredient() async {
    final picked = await showAppSheet<(Ingredient?,)>(context, (_) => _IngredientPicker(selected: _ingredient));
    if (picked == null || !mounted) return;
    setState(() {
      _ingredient = picked.$1;
      _load();
    });
  }

  static String _hint(RankBy by) => switch (by) {
        RankBy(diet: Diet.all) => 'Durchschnitt aus Soße, Fleisch, Salat und Brot',
        RankBy(diet: Diet.vegetarian) => 'Falafel, Halloumi und veganer Döner mit Soße, Salat und Brot',
        RankBy(diet: Diet.vegan) => 'Falafel, veganer Döner, vegane Soße und Hummus mit Salat und Brot',
        RankBy(item: RatingItem.ayran) => 'Nur selbstgemachter Ayran',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final location = context.watch<LocationService>();
    final diet = context.watch<Session>().diet;
    final center = _center;
    // A new diet starts at its own main score.
    if (diet != _diet) {
      _diet = diet;
      _by = RankBy.forDiet(diet).first;
      _ranking = null;
    }
    final by = _by!;
    if (_ranking == null ||
        location.visiting?.name != _visiting ||
        (center != null &&
            Geolocator.distanceBetween(center.latitude, center.longitude, location.center.latitude, location.center.longitude) >
                _reloadDistance)) {
      _load();
    }

    return FutureBuilder<RankingDto>(
      future: _ranking,
      builder: (context, snapshot) {
        final ranking = snapshot.connectionState == ConnectionState.done ? snapshot.data : null;
        final city = ranking?.city;
        final title = switch (diet) { Diet.all => 'Ranking', Diet.vegetarian => 'Veggie-Ranking', Diet.vegan => 'Vegan-Ranking' };
        // Vegans don't need the places where people found nothing vegan.
        final entries = [
          for (final e in ranking?.entries ?? const <RankingEntryDto>[])
            if (diet != Diet.vegan || e.place.veganOptions != false) e,
        ];
        return Scaffold(
          appBar: AppBar(
            title: Text(city == null ? title : '$title $city'),
            actions: [
              IconButton(icon: const Icon(Icons.travel_explore), tooltip: 'Andere Stadt ansehen', onPressed: () => showCityPicker(context)),
              IconButton(icon: const Icon(Icons.info_outline), tooltip: 'So funktionieren Bewertungen', onPressed: () => showRatingInfo(context)),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () async {
              setState(_load);
              await _ranking!.catchError((_) => RankingDto(by: by, entries: const []));
            },
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final option in RankBy.forDiet(diet))
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(option.diet == Diet.vegan || option.diet == Diet.vegetarian
                                ? '${option.diet!.emoji} ${option.label}'
                                : option.label),
                            selected: option == by,
                            onSelected: (_) => setState(() {
                              _by = option;
                              _load();
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final price in _maxPrices)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            avatar: price == null ? const Text('💶') : null,
                            label: Text(price == null ? 'Jeder Preis' : 'bis ${formatPrice(price).replaceAll(',00', '')}'),
                            selected: price == _maxPrice,
                            onSelected: (_) => setState(() {
                              _maxPrice = price;
                              _load();
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilterChip(
                    avatar: const Text('🧅'),
                    label: Text(_ingredient == null ? 'Jede Zutat' : 'Mit ${_ingredient!.label}'),
                    selected: _ingredient != null,
                    showCheckmark: false,
                    onSelected: (_) => _pickIngredient(),
                  ),
                ),
                if (_hint(by).isNotEmpty || _maxPrice != null || _ingredient != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      [
                        if (_hint(by).isNotEmpty) _hint(by),
                        if (_maxPrice != null) 'Nur Läden, deren Döner laut Bewertungen meist höchstens ${formatPrice(_maxPrice!)} kostet',
                        if (_ingredient case final i?) 'Nur Läden, bei denen die meisten Experten ${i.label} im Döner hatten',
                      ].join(' · '),
                      style: TextStyle(color: Theme.of(context).colorScheme.outline, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 16),
                if (snapshot.connectionState != ConnectionState.done)
                  const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
                else if (snapshot.hasError)
                  EmptyState(
                    icon: Icons.cloud_off,
                    title: 'Ranking nicht geladen',
                    message: '${snapshot.error}',
                    action: OutlinedButton(onPressed: () => setState(_load), child: const Text('Erneut versuchen')),
                  )
                else if (city == null)
                  EmptyState(
                    icon: Icons.emoji_events_outlined,
                    title: 'Hier gibt es noch kein Ranking',
                    message: 'Die App kennt in deiner Gegend noch keine Döner-Läden. Schau auf der Karte, was es gibt, '
                        'oder wo man anderswo am besten isst.',
                    action: OutlinedButton.icon(
                      icon: const Icon(Icons.travel_explore),
                      label: const Text('Andere Stadt ansehen'),
                      onPressed: () => showCityPicker(context),
                    ),
                  )
                else if (entries.isEmpty && _ingredient != null)
                  EmptyState(
                    icon: Icons.search_off,
                    title: 'Nichts mit ${_ingredient!.label} gefunden',
                    message: 'Zutaten kommen von Experten in den Bewertungen. Schalt den Expertenmodus in den Einstellungen ein '
                        'und trag beim nächsten Döner ein, was drin war.',
                    action: OutlinedButton(
                      onPressed: () => setState(() {
                        _ingredient = null;
                        _load();
                      }),
                      child: const Text('Jede Zutat'),
                    ),
                  )
                else if (entries.isEmpty && _maxPrice != null)
                  EmptyState(
                    icon: Icons.euro,
                    title: 'Nichts bis ${formatPrice(_maxPrice!)} gefunden',
                    message: 'Preise kommen aus den Bewertungen. Trag beim nächsten Döner ein, was du bezahlt hast.',
                    action: OutlinedButton(
                      onPressed: () => setState(() {
                        _maxPrice = null;
                        _load();
                      }),
                      child: const Text('Jeder Preis'),
                    ),
                  )
                else if (entries.isEmpty)
                  EmptyState(
                    icon: Icons.emoji_events_outlined,
                    title: 'Noch keine Bewertungen in $city',
                    message: by == RankBy.overall
                        ? 'Bewerte deinen Stammladen – dann steht er hier ganz oben.'
                        : 'Für ${by.label} hat hier noch niemand eine Note vergeben.',
                    action: OutlinedButton.icon(
                      icon: const Icon(Icons.travel_explore),
                      label: const Text('Andere Stadt ansehen'),
                      onPressed: () => showCityPicker(context),
                    ),
                  )
                else ...[
                  if (ranking!.bestOf case final bestOf?)
                    BestOfBanner(bestOf: bestOf)
                  else if (DateTime.now().year >= firstBestOfYear)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Am 1. Januar erscheint die Bestenliste ${DateTime.now().year} für $city: Läden mit mindestens '
                        '$bestOfMinReviews Bewertungen aus diesem Jahr.',
                        style: TextStyle(color: Theme.of(context).colorScheme.outline, fontSize: 12.5),
                      ),
                    ),
                  const Divider(),
                  for (final (i, entry) in entries.indexed) _RankingRow(rank: i + 1, entry: entry),
                ],
                const GoogleAttribution(),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Picks the ingredient the ranking filters by; pops `(null,)` for any.
class _IngredientPicker extends StatelessWidget {
  final Ingredient? selected;
  const _IngredientPicker({required this.selected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget chip(Ingredient? i) => ChoiceChip(
          label: Text(i?.label ?? 'Jede Zutat'),
          selected: i == selected,
          onSelected: (_) => Navigator.pop(context, (i,)),
        );
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text('Mit Zutat 🧅', style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(
            'Nur Läden, bei denen die meisten Experten sie im Döner hatten.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          chip(null),
          for (final group in IngredientGroup.values) ...[
            const SizedBox(height: 12),
            Text(group.label, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [for (final i in Ingredient.values.where((i) => i.group == group)) chip(i)],
            ),
          ],
        ],
      ),
    );
  }
}

class _RankingRow extends StatelessWidget {
  final int rank;
  final RankingEntryDto entry;
  const _RankingRow({required this.rank, required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HairlineRow(
      onTap: () => showPlaceDetail(context, entry.place),
      child: Row(
        children: [
          RankBadge(rank: rank),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.place.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (entry.price case final price?)
                  Text('💶 meist ${formatPrice(price)}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                if (entry.friends.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(children: [
                    Icon(Icons.group, size: 14, color: context.accent),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        entry.friends.map((f) => '${f.user.displayName} ${f.rating % 1 == 0 ? f.rating.toInt() : formatRating(f.rating)}').join(' · '),
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ]),
                ],
              ],
            ),
          ),
          ScoreBlock(average: entry.average, count: entry.count),
        ],
      ),
    );
  }
}
