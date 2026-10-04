import 'package:doener_models/doener_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

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
  late Future<(PlaceSummaryDto, List<ReviewDto>)> _community = _loadCommunity();

  Future<(PlaceSummaryDto, List<ReviewDto>)> _loadCommunity() async {
    final api = context.read<Session>().api;
    final id = Uri.encodeComponent(widget.placeId);
    final results = await Future.wait([api.get('/places/$id/summary'), api.get('/places/$id/reviews')]);
    return (
      PlaceSummaryDto.fromJson(results[0] as Map<String, dynamic>),
      [for (final r in results[1] as List) ReviewDto.fromJson(r as Map<String, dynamic>)],
    );
  }

  Future<void> _review(PlaceDto place) async {
    final saved = await showAppSheet<bool>(context, (_) => ReviewSheet(place: place));
    if (saved == true && mounted) {
      final data = context.read<AppData>();
      await data.sync();
      if (!mounted) return;
      setState(() => _community = _loadCommunity());
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
    final place = data.places[widget.placeId] ?? widget.fallback;
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
                    if (place.specialNote != null) ...[
                      const SizedBox(height: 6),
                      Chip(
                        label: Text(place.specialNote!),
                        labelStyle: const TextStyle(color: doenerOrange, fontSize: 12),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ],
                ),
              ),
              _RatingBadge(rating: place.avgRating, count: place.reviewCount),
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
          ReviewCard(review: ownReview.dto, onEdit: () => _review(place)),
        ],
        FutureBuilder(
          future: _community,
          builder: (context, snapshot) {
            final result = snapshot.data;
            if (result == null) return const SizedBox.shrink();
            final (summary, reviews) = result;
            final others = reviews.where((r) => r.userId != context.read<Session>().user?.id).toList();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (summary.reviewCount > 0) ...[
                  const SizedBox(height: 20),
                  const SectionTitle(icon: Icons.groups, title: 'Community'),
                  GlassCard(child: Text(summary.summaryText)),
                ],
                if (others.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  SectionTitle(icon: Icons.rate_review, title: 'Bewertungen (${others.length})'),
                  for (final r in others) Padding(padding: const EdgeInsets.only(bottom: 8), child: ReviewCard(review: r, showAuthor: true)),
                ],
              ],
            );
          },
        ),
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
}

class ReviewCard extends StatelessWidget {
  final ReviewDto review;
  final bool showAuthor;
  final VoidCallback? onEdit;
  const ReviewCard({super.key, required this.review, this.showAuthor = false, this.onEdit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      onTap: onEdit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (showAuthor) ...[Text(review.userName, style: const TextStyle(fontWeight: FontWeight.w600)), const SizedBox(width: 8)],
              DoenerRating(value: review.rating, size: 14),
              const Spacer(),
              if (onEdit != null) Icon(Icons.edit, size: 16, color: theme.colorScheme.outline),
            ],
          ),
          if (review.sauceRating != null || review.fleischRating != null || review.brotRating != null) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 12, runSpacing: 4, children: [
              if (review.sauceRating != null) DimensionChip(label: 'Soße', value: review.sauceRating!),
              if (review.fleischRating != null) DimensionChip(label: 'Fleisch', value: review.fleischRating!),
              if (review.brotRating != null) DimensionChip(label: 'Brot', value: review.brotRating!),
            ]),
          ],
          if (review.text != null) ...[const SizedBox(height: 6), Text(review.text!)],
          const SizedBox(height: 6),
          Text(formatDate(review.updatedAt), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
        ],
      ),
    );
  }
}

class _RatingBadge extends StatelessWidget {
  final double? rating;
  final int count;
  const _RatingBadge({required this.rating, required this.count});

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
              rating == null ? '—' : formatRating(rating!),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: doenerOrange),
            ),
            Text(count == 1 ? '1 Bewertung' : '$count Bewertungen', style: Theme.of(context).textTheme.labelSmall),
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
