import 'package:doener_models/doener_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/session.dart';

const doenerOrange = Color(0xFFFF8C00);

ThemeData buildTheme(Brightness brightness) {
  // Buttons in the brand orange (as in the iOS app) instead of the muted seed tone.
  final scheme = ColorScheme.fromSeed(seedColor: doenerOrange, brightness: brightness)
      .copyWith(primary: doenerOrange, onPrimary: Colors.white);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
    ),
  );
}

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.color});

  @override
  Widget build(BuildContext context) => Card(
        color: color,
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      );
}

/// 1–5 rating shown as fork-and-knife icons.
class DoenerRating extends StatelessWidget {
  final int value;
  final double size;
  final ValueChanged<int>? onChanged;
  const DoenerRating({super.key, required this.value, this.size = 16, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final inactive = Theme.of(context).colorScheme.outlineVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          GestureDetector(
            onTap: onChanged == null ? null : () => onChanged!(i),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: size * 0.08),
              child: AnimatedScale(
                scale: onChanged != null && i == value ? 1.12 : 1,
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  i <= value ? Icons.restaurant : Icons.restaurant_outlined,
                  size: size,
                  color: i <= value ? doenerOrange : inactive,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class DimensionChip extends StatelessWidget {
  final String label;
  final int value;
  const DimensionChip({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(width: 3),
          DoenerRating(value: value, size: 11),
        ],
      );
}

/// What a review rated, as small chips — only the food [diet] eats.
class RatingChips extends StatelessWidget {
  final Map<RatingItem, int> ratings;
  final Diet diet;
  const RatingChips({super.key, required this.ratings, required this.diet});

  @override
  Widget build(BuildContext context) {
    final items = [for (final item in RatingItem.values) if (ratings[item] != null && diet.allows(item.diet)) item];
    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 12, runSpacing: 4, children: [
      for (final item in items) DimensionChip(label: item.isDoener ? item.label : '${item.emoji} ${item.label}', value: ratings[item]!),
    ]);
  }
}

/// A check-in or review in a feed. [highlight] marks friends. Reviews show
/// [score] and the rated items [diet] eats.
class ActivityCard extends StatelessWidget {
  final FeedItemType type;
  final String title;
  final String subtitle;
  final DateTime timestamp;
  final double? score;
  final Map<RatingItem, int> ratings;
  final Diet diet;
  final String? text;
  final String? foodType;
  final String? photoId;
  final Uint8List? photo;
  final bool onSite;
  final bool pending;
  final bool highlight;
  final VoidCallback? onTap;

  const ActivityCard({
    super.key,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.timestamp,
    this.score,
    this.ratings = const {},
    this.diet = Diet.all,
    this.text,
    this.foodType,
    this.photoId,
    this.photo,
    this.onSite = false,
    this.pending = false,
    this.highlight = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isVisit = type == FeedItemType.visit;
    final color = isVisit ? Colors.green : doenerOrange;
    return GlassCard(
      onTap: onTap,
      color: highlight ? doenerOrange.withValues(alpha: 0.1) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: color.withValues(alpha: 0.12),
                child: isVisit && foodType != null
                    ? Text(foodEmoji(foodType), style: const TextStyle(fontSize: 18))
                    : Icon(isVisit ? Icons.check_circle : Icons.restaurant, size: 18, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                      if (highlight) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.group, size: 14, color: doenerOrange, semanticLabel: 'Freund'),
                      ],
                      if (onSite) ...[const SizedBox(width: 8), const OnSiteBadge()],
                    ]),
                    Text(subtitle, style: const TextStyle(color: doenerOrange)),
                  ],
                ),
              ),
              if (pending) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.cloud_upload_outlined, size: 16)),
              Text(relativeTime(timestamp), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
          if (score != null) ...[const SizedBox(height: 8), DoenerRating(value: score!.round(), size: 14)],
          if (ratings.isNotEmpty) ...[const SizedBox(height: 6), RatingChips(ratings: ratings, diet: diet)],
          if (text != null && text!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(text!, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          ],
          if (photo != null || photoId != null) ...[const SizedBox(height: 10), ReviewPhoto(photoId: photoId, bytes: photo)],
        ],
      ),
    );
  }
}

/// The reviewer checked in at the place.
class OnSiteBadge extends StatelessWidget {
  const OnSiteBadge({super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Hat hier eingecheckt',
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.verified, size: 14, color: Colors.green.shade600),
          const SizedBox(width: 3),
          Text('vor Ort', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.green.shade600, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// A review photo: [bytes] while it waits for upload, otherwise loaded by
/// [photoId]. A tap shows it whole.
class ReviewPhoto extends StatelessWidget {
  final String? photoId;
  final Uint8List? bytes;
  final double height;
  const ReviewPhoto({super.key, this.photoId, this.bytes, this.height = 180});

  @override
  Widget build(BuildContext context) {
    final image = bytes != null ? MemoryImage(bytes!) : NetworkImage('${context.read<Session>().apiBase}/photos/$photoId') as ImageProvider;
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: InteractiveViewer(child: Image(image: image, fit: BoxFit.contain)),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image(
          image: image,
          height: height,
          width: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (context, _, _) => Container(
            height: height,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Icon(Icons.broken_image_outlined, color: Theme.of(context).colorScheme.outline),
          ),
        ),
      ),
    );
  }
}

/// Place number in a ranking — cups for the podium.
class RankBadge extends StatelessWidget {
  final int rank;
  const RankBadge({super.key, required this.rank});

  @override
  Widget build(BuildContext context) {
    final color = switch (rank) { 1 => doenerOrange, 2 => Colors.grey, 3 => Colors.brown, _ => Colors.transparent };
    return CircleAvatar(
      radius: 18,
      backgroundColor: color.withValues(alpha: 0.15),
      child: rank <= 3
          ? Icon(Icons.emoji_events, size: 18, color: color)
          : Text('$rank', style: const TextStyle(fontWeight: FontWeight.bold)),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  const EmptyState({super.key, required this.icon, required this.title, required this.message, this.action});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline), textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;
  const SectionTitle({super.key, required this.icon, required this.title, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: doenerOrange),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
            ?trailing,
          ],
        ),
      );
}

class Pill extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  const Pill({super.key, required this.child, this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        elevation: 3,
        shape: const StadiumBorder(),
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), child: child),
        ),
      );
}

String formatRating(double value) => value.toStringAsFixed(1).replaceAll('.', ',');

String formatDate(DateTime date) => DateFormat('d. MMM y', 'de').format(date.toLocal());

String formatDateTime(DateTime date) => DateFormat('d. MMM y, HH:mm', 'de').format(date.toLocal());

/// A calendar day like "2. Oktober" — dates without a time of day.
String formatDay(DateTime day) => DateFormat('d. MMMM', 'de').format(day);

/// An opening Google announced: "am 15. Oktober", or "im Oktober" when only the month is known.
String formatOpening(String opensOn) {
  final parts = opensOn.split('-').map(int.parse).toList();
  final date = DateTime(parts[0], parts[1], parts.length > 2 ? parts[2] : 1);
  return parts.length > 2 ? 'am ${formatDay(date)}' : 'im ${DateFormat('MMMM', 'de').format(date)}';
}

String relativeTime(DateTime date) {
  final diff = DateTime.now().difference(date);
  if (diff.inMinutes < 1) return 'gerade eben';
  if (diff.inMinutes < 60) return 'vor ${diff.inMinutes} Min.';
  if (diff.inHours < 24) return 'vor ${diff.inHours} Std.';
  if (diff.inDays == 1) return 'gestern';
  if (diff.inDays < 7) return 'vor ${diff.inDays} Tagen';
  return formatDate(date);
}

String foodEmoji(String? foodType) => FoodItem.byId(foodType)?.emoji ?? '✅';

IconData achievementIcon(AchievementType type) => switch (type) {
      AchievementType.firstBite => Icons.restaurant,
      AchievementType.critic => Icons.rate_review,
      AchievementType.regular => Icons.repeat,
      AchievementType.explorer => Icons.map,
      AchievementType.connoisseur => Icons.workspace_premium,
      AchievementType.berlinTour || AchievementType.hamburgTour => Icons.location_city,
      AchievementType.stampCollectorSilver => Icons.verified_outlined,
      AchievementType.stampCollectorGold => Icons.verified,
      AchievementType.nightOwl => Icons.nightlight_round,
      AchievementType.socialButterfly => Icons.groups,
    };

Color tierColor(StampTier tier) => switch (tier) {
      StampTier.doenerneuling => Colors.grey,
      StampTier.doenerfreund => Colors.brown,
      StampTier.doenerfan => doenerOrange,
      StampTier.doenerprofi => Colors.red,
      StampTier.doenermeister => Colors.purple,
      StampTier.doenerlegende => Colors.amber,
    };

void showMessage(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

/// Consistent modal sheet used for all forms.
Future<T?> showAppSheet<T>(BuildContext context, WidgetBuilder builder) => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: builder(context),
      ),
    );
