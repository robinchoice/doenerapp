import 'package:doener_models/doener_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/app_data.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';
import '../../core/maps.dart';
import 'review_sheet.dart';

Future<void> showPlaceDetail(BuildContext context, PlaceDto place) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 1,
        builder: (context, controller) => PlaceDetail(placeId: place.placeId, fallback: place, controller: controller),
      ),
    );

class PlaceDetail extends StatefulWidget {
  final String placeId;
  final PlaceDto fallback;
  final ScrollController? controller;
  const PlaceDetail({super.key, required this.placeId, required this.fallback, this.controller});

  @override
  State<PlaceDetail> createState() => _PlaceDetailState();
}

class _PlaceDetailState extends State<PlaceDetail> {
  PlaceSummaryDto? _summary;
  List<ReviewDto> _reviews = const [];

  @override
  void initState() {
    super.initState();
    _loadCommunity();
  }

  Future<void> _loadCommunity() async {
    final api = context.read<Session>().api;
    final id = Uri.encodeComponent(widget.placeId);
    try {
      final results = await Future.wait([api.get('/places/$id/summary'), api.get('/places/$id/reviews')]);
      if (!mounted) return;
      setState(() {
        _summary = PlaceSummaryDto.fromJson(results[0] as Map<String, dynamic>);
        _reviews = [for (final r in results[1] as List) ReviewDto.fromJson(r as Map<String, dynamic>)];
      });
    } on OfflineException {
      // The place itself is cached; what others say shows up next time.
    } on ApiException {
      // Same.
    }
  }

  Future<void> _review(PlaceDto place) async {
    final saved = await showAppSheet<bool>(context, (_) => ReviewSheet(place: place, summary: _summary));
    if (saved == true && mounted) {
      final data = context.read<AppData>();
      await data.sync();
      if (!mounted) return;
      await _loadCommunity();
      await data.refreshPlace(place.placeId).catchError((_) {});
    }
  }

  Future<void> _openRoute(PlaceDto place) async {
    final destination = '${place.latitude},${place.longitude}';
    final uri = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
        ? Uri.parse('https://maps.apple.com/?daddr=$destination')
        : Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$destination');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _editNote(PlaceDto place, String? current) async {
    final controller = TextEditingController(text: current);
    final result = await showAppSheet<String>(
      context,
      (context) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          Text('Notiz zu ${place.name}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(controller: controller, autofocus: true, minLines: 4, maxLines: 10, decoration: const InputDecoration(hintText: 'Deine Notiz…')),
          const SizedBox(height: 12),
          Row(
            children: [
              if (current != null)
                TextButton(onPressed: () => Navigator.of(context).pop(''), child: const Text('Löschen', style: TextStyle(color: Colors.red))),
              const Spacer(),
              FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Speichern')),
            ],
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && mounted) await context.read<AppData>().setNote(place.placeId, result);
  }

  @override
  Widget build(BuildContext context) {
    final data = context.watch<AppData>();
    final session = context.watch<Session>();
    final diet = session.diet;
    final place = data.places[widget.placeId] ?? widget.fallback;
    final summary = _summary;
    final menu = summary == null ? const <Widget>[] : _menuRows(place, summary, diet);
    final theme = Theme.of(context);
    final note = data.notes[place.placeId];
    final ownReview = data.reviews[place.placeId];
    final visits = data.visitsAt(place.placeId);
    final isFavorite = data.favorites.contains(place.placeId);
    final addressLine = [place.postalCode, place.city].whereType<String>().join(' ');

    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        GlassCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(place.name, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                    if (place.address != null) ...[
                      const SizedBox(height: 4),
                      Row(children: [
                        const Icon(Icons.place_outlined, size: 16),
                        const SizedBox(width: 4),
                        Expanded(child: Text(place.address!)),
                      ]),
                    ],
                    if (addressLine.isNotEmpty) Text(addressLine, style: TextStyle(color: theme.colorScheme.outline)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      if (place.openedOn case final opened? when DateTime.now().difference(opened).inDays < 30)
                        _Fact('🎉 Neu seit ${formatDay(opened)}', Colors.red.shade700),
                      if (place.veganOptions == true) _Fact('🌱 Vegane Optionen', Colors.green.shade700),
                      if (place.veganOptions == false) _Fact('Nichts Veganes', theme.colorScheme.outline),
                      if (diet != Diet.vegan && summary?.ayranHomemade == true) const _Fact('🥛 Ayran selbstgemacht', doenerOrange),
                      if (diet != Diet.vegan && summary?.ayranHomemade == false) _Fact('Ayran gekauft', theme.colorScheme.outline),
                      for (final special in summary?.specials ?? const <Ingredient>[]) _Fact('✨ ${special.label}', doenerOrange),
                    ]),
                  ],
                ),
              ),
              _RatingBadge(score: place.score(diet), label: diet.scoreLabel),
            ],
          ),
        ),
        if (place.openingHours != null) ...[
          const SizedBox(height: 12),
          GlassCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.schedule, color: doenerOrange),
                const SizedBox(width: 10),
                Expanded(child: Text(place.openingHours!)),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            _ActionTile(
              icon: isFavorite ? Icons.favorite : Icons.favorite_border,
              label: isFavorite ? 'Favorit' : 'Merken',
              color: Colors.pink,
              onTap: () => data.toggleFavorite(place.placeId),
            ),
            _ActionTile(icon: Icons.restaurant, label: 'Bewerten', color: doenerOrange, onTap: () => _review(place)),
            _ActionTile(
              icon: note != null ? Icons.sticky_note_2 : Icons.sticky_note_2_outlined,
              label: 'Notiz',
              color: Colors.blue,
              onTap: () => _editNote(place, note),
            ),
            _ActionTile(icon: Icons.directions, label: 'Route', color: Colors.purple, onTap: () => _openRoute(place)),
          ],
        ),
        if (note != null) ...[
          const SizedBox(height: 12),
          GlassCard(
            onTap: () => _editNote(place, note),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Notiz', style: theme.textTheme.labelMedium?.copyWith(color: Colors.blue)),
                const SizedBox(height: 4),
                Text(note),
              ],
            ),
          ),
        ],
        if (ownReview != null) ...[
          const SizedBox(height: 20),
          SectionTitle(
            icon: Icons.person,
            title: 'Deine Bewertung',
            trailing: ownReview.pending ? const Tooltip(message: 'Wird synchronisiert', child: Icon(Icons.cloud_upload_outlined, size: 18)) : null,
          ),
          ReviewCard(review: ownReview.dto, photo: ownReview.photo, onEdit: () => _review(place)),
        ],
        if (menu.isNotEmpty) ...[
          const SizedBox(height: 20),
          const SectionTitle(icon: Icons.restaurant_menu, title: 'Was es hier gibt'),
          GlassCard(child: Column(children: menu)),
        ],
        if (session.expertMode && summary != null) ...[
          const SizedBox(height: 20),
          SectionTitle(
            icon: Icons.manage_search,
            title: 'Mit allem heißt hier …',
            trailing: summary.experts == 0
                ? null
                : Text('${summary.experts} ${summary.experts == 1 ? 'Angabe' : 'Angaben'}', style: TextStyle(color: theme.colorScheme.outline)),
          ),
          _IngredientsCard(summary: summary, diet: diet),
        ],
        if (_reviews.where((r) => r.userId != session.user?.id).toList() case final others when others.isNotEmpty) ...[
          const SizedBox(height: 20),
          SectionTitle(icon: Icons.rate_review, title: 'Bewertungen (${others.length})'),
          for (final r in others) Padding(padding: const EdgeInsets.only(bottom: 8), child: ReviewCard(review: r, showAuthor: true)),
        ],
        if (visits.isNotEmpty) ...[
          const SizedBox(height: 20),
          SectionTitle(icon: Icons.check_circle, title: 'Deine Besuche (${visits.length})'),
          for (final v in visits)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassCard(
                child: Row(
                  children: [
                    Text(foodEmoji(v.dto.foodType), style: const TextStyle(fontSize: 24)),
                    const SizedBox(width: 12),
                    Expanded(child: Text(formatDateTime(v.dto.visitedAt), style: const TextStyle(fontWeight: FontWeight.w600))),
                    if (FoodItem.byId(v.dto.foodType) case final food?) Chip(label: Text(food.label), visualDensity: VisualDensity.compact),
                    if (v.pending) const Icon(Icons.cloud_upload_outlined, size: 18),
                  ],
                ),
              ),
            ),
        ],
        const SizedBox(height: 20),
        if (mapsAvailable)
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            // A rounded clip on this map makes iOS skip drawing the sheets above it wherever they
            // cover the big map (Flutter 3.47 engine bug, undone by flutter/flutter#190003).
            clipBehavior: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS ? Clip.none : Clip.antiAlias,
            child: SizedBox(
              height: 160,
              child: Stack(
                children: [
                  IgnorePointer(
                    child: GoogleMap(
                      initialCameraPosition: CameraPosition(target: LatLng(place.latitude, place.longitude), zoom: 16),
                      liteModeEnabled: true,
                      zoomControlsEnabled: false,
                      mapToolbarEnabled: false,
                      markers: {
                        Marker(
                          markerId: MarkerId(place.placeId),
                          position: LatLng(place.latitude, place.longitude),
                          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
                        ),
                      },
                    ),
                  ),
                  // IgnorePointer doesn't reach the map's DOM element on the web.
                  if (kIsWeb) Positioned.fill(child: PointerInterceptor(child: const SizedBox.expand())),
                ],
              ),
            ),
          )
        else
          const GoogleAttribution(),
      ],
    );
  }

  /// The Döner with its sauce, meat and bread first, then everything else the
  /// diet eats — averages of all reviews.
  List<Widget> _menuRows(PlaceDto place, PlaceSummaryDto summary, Diet diet) {
    final doener = place.score(Diet.all);
    final rows = <Widget>[
      if (diet == Diet.all && doener.average != null)
        _MenuRow(
          emoji: '🥙',
          label: 'Döner',
          detail: [
            for (final item in RatingItem.doenerItems)
              if (summary.items[item] case final avg?) '${item.label} ${formatRating(avg.average)}',
          ].join(' · '),
          average: doener.average!,
          count: doener.count,
        ),
      for (final e in summary.items.entries)
        if (diet.allows(e.key.diet) && !(diet == Diet.all && e.key.isDoener))
          _MenuRow(emoji: e.key.emoji, label: e.key.label, detail: e.key.hint, average: e.value.average, count: e.value.count),
    ];
    return [
      for (final (i, row) in rows.indexed) ...[if (i > 0) const Divider(height: 1), row],
    ];
  }
}

class _Fact extends StatelessWidget {
  final String text;
  final Color color;
  const _Fact(this.text, this.color);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500)),
      );
}

class _MenuRow extends StatelessWidget {
  final String emoji;
  final String label;
  final String? detail;
  final double average;
  final int count;
  const _MenuRow({required this.emoji, required this.label, this.detail, required this.average, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(width: 30, child: Text(emoji, style: const TextStyle(fontSize: 18))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                if (detail != null && detail!.isNotEmpty) Text(detail!, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
          ),
          DoenerRating(value: average.round(), size: 13),
          const SizedBox(width: 8),
          Text(formatRating(average), style: const TextStyle(color: doenerOrange, fontWeight: FontWeight.bold)),
          SizedBox(width: 36, child: Text('($count)', textAlign: TextAlign.right, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline))),
        ],
      ),
    );
  }
}

/// What most experts got with "mit allem", the specials marked.
class _IngredientsCard extends StatelessWidget {
  final PlaceSummaryDto summary;
  final Diet diet;
  const _IngredientsCard({required this.summary, required this.diet});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (summary.experts == 0) {
      return GlassCard(
        child: Text(
          'Noch hat niemand eingetragen, was „mit allem“ hier heißt. Im Expertenmodus fragt die Bewertung danach.',
          style: TextStyle(color: theme.colorScheme.outline),
        ),
      );
    }
    final lines = [
      for (final group in IngredientGroup.values)
        if (summary.ingredients.where((i) => i.group == group).toList() case final list when list.isNotEmpty)
          (group.label, list.map((i) => i.isSpecial ? '${i.label} ✨' : i.label).join(' · ')),
      if (diet == Diet.all && (summary.meat != null || summary.skewer != null))
        ('Fleisch', [?summary.meat?.label, ?summary.skewer?.label].join(' · ')),
      if (summary.bread case final bread?) ('Brot', bread.label),
    ];
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, (title, text)) in lines.indexed) ...[
            if (i > 0) const SizedBox(height: 8),
            Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
            Text(text),
          ],
        ],
      ),
    );
  }
}

class ReviewCard extends StatelessWidget {
  final ReviewDto review;

  /// The own photo while it waits for upload.
  final Uint8List? photo;
  final bool showAuthor;
  final VoidCallback? onEdit;
  const ReviewCard({super.key, required this.review, this.photo, this.showAuthor = false, this.onEdit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final diet = context.watch<Session>().diet;
    return GlassCard(
      onTap: onEdit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (showAuthor) ...[Text(review.userName, style: const TextStyle(fontWeight: FontWeight.w600)), const SizedBox(width: 8)],
              if (review.headline(diet) case final score?) DoenerRating(value: score.round(), size: 14),
              if (review.onSite) ...[const SizedBox(width: 8), const OnSiteBadge()],
              const Spacer(),
              if (onEdit != null) Icon(Icons.edit, size: 16, color: theme.colorScheme.outline),
            ],
          ),
          if (review.ratings.isNotEmpty) ...[const SizedBox(height: 6), RatingChips(ratings: review.ratings, diet: diet)],
          if (review.text != null) ...[const SizedBox(height: 6), Text(review.text!)],
          if (photo != null || review.photoId != null) ...[const SizedBox(height: 10), ReviewPhoto(photoId: review.photoId, bytes: photo)],
          const SizedBox(height: 6),
          Text(formatDate(review.updatedAt), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
        ],
      ),
    );
  }
}

/// The main score of the user's diet: Döner, without meat or vegan.
class _RatingBadge extends StatelessWidget {
  final ({double? average, int count}) score;
  final String label;
  const _RatingBadge({required this.score, required this.label});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: doenerOrange.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Text(
              score.average == null ? '—' : formatRating(score.average!),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: doenerOrange),
            ),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            Text(score.count == 1 ? '1 Bewertung' : '${score.count} Bewertungen', style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      );
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionTile({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 12),
            onTap: onTap,
            child: Column(
              children: [
                CircleAvatar(radius: 20, backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, color: color, size: 20)),
                const SizedBox(height: 6),
                Text(label, style: Theme.of(context).textTheme.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      );
}
