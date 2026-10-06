import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/app_data.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';
import '../settings/settings_screen.dart';
import '../social/friends.dart';
import '../social/invite.dart';
import 'mine.dart';

List<(FoodItem, int)> foodCounts(Iterable<VisitDto> visits) {
  final counts = <String, int>{};
  for (final v in visits) {
    if (v.foodType != null) counts[v.foodType!] = (counts[v.foodType!] ?? 0) + 1;
  }
  return [for (final f in FoodItem.all) if (counts[f.id] case final n?) (f, n)]..sort((a, b) => b.$2.compareTo(a.$2));
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String? _friendsLoadedFor;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final data = context.watch<AppData>();
    final friends = context.watch<Friends>();
    final user = session.user;

    if (user?.id != _friendsLoadedFor) {
      _friendsLoadedFor = user?.id;
      WidgetsBinding.instance.addPostFrameCallback((_) => friends.load());
    }

    final visits = data.visits.map((v) => v.dto).toList();
    final stats = ProfileStats.compute(visits: visits, reviewCount: data.reviews.length, cityOf: (id) => data.places[id]?.city);
    final foods = foodCounts(visits);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profil'),
        actions: [
          IconButton(
            tooltip: 'Einstellungen',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const BrandTile(size: 64),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(user?.displayName ?? 'Döner-Fan', style: displayStyle.copyWith(fontSize: 28, color: theme.colorScheme.onSurface)),
                          Text.rich(
                            TextSpan(children: [
                              if (stats.firstVisit != null) TextSpan(text: 'Seit ${DateFormat('MMMM y', 'de').format(stats.firstVisit!.toLocal())} · '),
                              TextSpan(text: stats.stampTier.displayName, style: TextStyle(color: context.accent, fontWeight: FontWeight.w600)),
                            ]),
                            style: TextStyle(color: theme.colorScheme.outline),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(),
                _MenuRow(
                  icon: Icons.group,
                  label: 'Freunde',
                  trailing: [
                    if (friends.incoming.isNotEmpty) Badge(label: Text('${friends.incoming.length}')),
                    const SizedBox(width: 8),
                    Text('${friends.accepted.length}', style: TextStyle(color: theme.colorScheme.outline)),
                  ],
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FriendsScreen())),
                ),
                _MenuRow(icon: Icons.qr_code_2, label: 'Freunde einladen', onTap: () => showAppSheet(context, (_) => const InviteSheet())),
                _MenuRow(
                  icon: Icons.history,
                  label: 'Meine Aktivität',
                  trailing: [if (data.pendingCount > 0) Badge(label: Text('${data.pendingCount}'))],
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyActivityScreen())),
                ),
                _MenuRow(
                  icon: Icons.storefront,
                  label: 'Meine Läden',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyPlacesScreen())),
                ),
                _MenuRow(
                  icon: Icons.auto_awesome,
                  label: 'Döner Wrapped ${DateTime.now().year}',
                  trailing: [Text('Dein Jahresrückblick', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline))],
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const WrappedScreen())),
                ),
                const SizedBox(height: 16),
                const Divider(),
                IntrinsicHeight(
                  child: Row(children: [
                    _StatCard(value: stats.totalVisits, label: 'Besuche'),
                    const VerticalDivider(width: 1),
                    _StatCard(value: stats.totalReviews, label: 'Bewertungen'),
                    const VerticalDivider(width: 1),
                    _StatCard(value: stats.uniquePlaces, label: 'Läden'),
                  ]),
                ),
                const Divider(),
                const SizedBox(height: 20),
                _StampCard(stats: stats),
                const SizedBox(height: 24),
                FoodStatsCard(foods: foods),
                const SizedBox(height: 24),
                _Achievements(unlocked: stats.unlockedAchievements(friendsCount: friends.accepted.length)),
              ],
            ),
          ),
          const PleasanceFooter(),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final List<Widget> trailing;
  final VoidCallback onTap;
  const _MenuRow({required this.icon, required this.label, this.trailing = const [], required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
          child: Row(children: [
            Icon(icon, color: context.accent, size: 22),
            const SizedBox(width: 14),
            Expanded(child: Text(label)),
            ...trailing,
            Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.outline),
          ]),
        ),
      );
}

class _StatCard extends StatelessWidget {
  final int value;
  final String label;
  const _StatCard({required this.value, required this.label});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(children: [
            Text('$value', style: numberStyle.copyWith(fontSize: 44, color: Theme.of(context).colorScheme.onSurface)),
            const SizedBox(height: 4),
            Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
          ]),
        ),
      );
}

class FoodStatsCard extends StatelessWidget {
  final List<(FoodItem, int)> foods;
  const FoodStatsCard({super.key, required this.foods});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(title: 'Dein Döner-Konsum'),
          if (foods.isEmpty) Text('Noch keine Check-ins mit Essenstyp', style: Theme.of(context).textTheme.bodySmall),
          for (final (food, count) in foods)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                SizedBox(width: 32, child: Text(food.emoji, style: const TextStyle(fontSize: 20))),
                SizedBox(width: 80, child: Text(food.label)),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) => Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: c.maxWidth * count / foods.first.$2,
                        height: 20,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(color: Theme.of(context).colorScheme.onSurface, borderRadius: BorderRadius.circular(6)),
                        child: Text('$count', style: TextStyle(color: Theme.of(context).colorScheme.surface, fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
        ],
      );
}

class _StampCard extends StatelessWidget {
  final ProfileStats stats;
  const _StampCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    final tier = stats.stampTier;
    final color = tierColor(context, tier);
    final scheme = Theme.of(context).colorScheme;
    final next = tier.nextTier;
    final inTier = stats.totalVisits - tier.stampsRequired;
    final dots = next == null ? 10 : next.stampsRequired - tier.stampsRequired;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          title: 'Stempelkarte',
          trailing: Chip(
            label: Text(tier.displayName, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
            backgroundColor: color.withValues(alpha: 0.15),
            side: BorderSide.none,
            visualDensity: VisualDensity.compact,
          ),
        ),
        GradientProgress(value: stats.stampProgress),
        const SizedBox(height: 6),
        Text(
          next == null ? 'Höchste Stufe erreicht!' : 'Noch ${stats.stampsToNextTier} Besuche bis ${next.displayName}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < dots; i++)
              CircleAvatar(
                radius: 8,
                backgroundColor: i < inTier || next == null ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.08),
                child: i < inTier || next == null ? Icon(Icons.check, size: 10, color: scheme.surface) : null,
              ),
          ],
        ),
      ],
    );
  }
}

class _Achievements extends StatelessWidget {
  final Set<AchievementType> unlocked;
  const _Achievements({required this.unlocked});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            title: 'Erfolge',
            trailing: Text('${unlocked.length}/${AchievementType.values.length}'),
          ),
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 0.8,
            children: [
              for (final type in AchievementType.values)
                Tooltip(
                  message: type.description,
                  triggerMode: TooltipTriggerMode.tap,
                  child: Column(children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor: unlocked.contains(type) ? Theme.of(context).colorScheme.secondaryContainer : Colors.grey.withValues(alpha: 0.08),
                      child: Icon(achievementIcon(type), color: unlocked.contains(type) ? context.accent : Colors.grey.withValues(alpha: 0.4)),
                    ),
                    const SizedBox(height: 4),
                    Text(type.title, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 10)),
                  ]),
                ),
            ],
          ),
        ],
      );
}

/// Yearly recap in five swipeable pages.
class WrappedScreen extends StatefulWidget {
  const WrappedScreen({super.key});

  @override
  State<WrappedScreen> createState() => _WrappedScreenState();
}

class _WrappedScreenState extends State<WrappedScreen> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final data = context.watch<AppData>();
    final year = DateTime.now().year;
    final visits = data.visits.map((v) => v.dto).where((v) => v.visitedAt.toLocal().year == year).toList();
    final reviewCount = data.reviews.values.where((r) => r.dto.createdAt.toLocal().year == year).length;
    final foods = foodCounts(visits);
    final byPlace = <String, List<VisitDto>>{};
    final byMonth = <int, int>{};
    for (final v in visits) {
      byPlace.putIfAbsent(v.placeId, () => []).add(v);
      final m = v.visitedAt.toLocal().month;
      byMonth[m] = (byMonth[m] ?? 0) + 1;
    }
    final topPlace = byPlace.values.fold<List<VisitDto>?>(null, (best, v) => best == null || v.length > best.length ? v : best);
    final busiestMonth = byMonth.entries.fold<MapEntry<int, int>?>(null, (best, e) => best == null || e.value > best.value ? e : best);
    final monthName = busiestMonth == null ? null : DateFormat('MMMM', 'de').format(DateTime(year, busiestMonth.key));

    // Always dark, like the tile: big numbers glow, the text stays light.
    final highlight = accentFor(Brightness.dark);
    Widget big(String text) => Text(text, style: numberStyle.copyWith(fontSize: 96, color: highlight), textAlign: TextAlign.center);
    Widget label(String text) => Text(text, style: const TextStyle(color: nightText, fontSize: 20), textAlign: TextAlign.center);
    Widget emoji(String e) => Text(e, style: const TextStyle(fontSize: 80));

    final pages = [
      [emoji('🥙'), big('${visits.length}'), label('Döner-Besuche in $year')],
      if (foods.isNotEmpty)
        [emoji(foods.first.$1.emoji), label('Dein Favorit:'), big(foods.first.$1.label), label('${foods.first.$2}×')]
      else
        [emoji('🤷'), label('Noch kein Lieblings-Essen')],
      [emoji('📍'), if (topPlace != null) ...[label('Dein Stammladen:'), big(topPlace.first.placeName), label('${topPlace.length} Besuche')] else label('Noch kein Stammladen')],
      [emoji('🗺️'), big('${byPlace.length}'), label('verschiedene Läden entdeckt')],
      [
        emoji('🏆'),
        label('Dein $year'),
        const SizedBox(height: 16),
        label('🥙 ${visits.length} Besuche'),
        label('⭐ $reviewCount Bewertungen'),
        label('📍 ${byPlace.length} Läden'),
        if (foods.isNotEmpty) label('${foods.first.$1.emoji} ${foods.first.$2}× ${foods.first.$1.label}'),
        if (monthName != null) label('📅 Aktivster Monat: $monthName'),
      ],
    ];

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: night,
      appBar: AppBar(backgroundColor: Colors.transparent, foregroundColor: nightText),
      body: SizedBox.expand(
        child: Stack(
          children: [
            PageView(
              onPageChanged: (p) => setState(() => _page = p),
              children: [
                for (final children in pages)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: FittedBox(fit: BoxFit.scaleDown, child: Column(mainAxisSize: MainAxisSize.min, children: children)),
                    ),
                  ),
              ],
            ),
            Positioned(
              bottom: 32,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < pages.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.all(3),
                      width: i == _page ? 22 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        gradient: i == _page ? actionGradient : null,
                        color: i == _page ? null : Colors.white.withValues(alpha: 0.18),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
