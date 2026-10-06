import 'package:doener_models/doener_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/app_data.dart';
import '../../core/location.dart';
import '../../core/maps.dart';
import '../../core/reminders.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';
import '../place/place_detail.dart';
import '../place/review_sheet.dart';
import '../social/friends.dart';
import '../social/invite.dart';

/// Moving further than this loads the area around the new position.
const _reloadDistance = 1000.0;

/// Best places and trends around, then what friends and people nearby ate.
/// Until they've done it, new users get two tasks to get going.
class StartScreen extends StatefulWidget {
  final VoidCallback onOpenMap;
  const StartScreen({super.key, required this.onOpenMap});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  List<PlaceDto> _top = [];
  List<PlaceDto> _trending = [];
  NewPlacesDto _news = const NewPlacesDto();
  List<LiveStatusDto> _live = [];
  bool _areaLoaded = false;
  final _items = <FeedItem>[];
  String? _cursor;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;
  bool _friendsOnly = false;

  /// Bumped on every reload, so a page still on its way for the old filter is dropped.
  int _feedGeneration = 0;

  /// Where the shown data was loaded for — the user's position or Freiburg.
  LatLng? _center;
  String? _loadedFor;

  Future<void> _refresh() async {
    _center = context.read<LocationService>().position ?? fallbackLocation;
    await Future.wait([_loadArea(), _loadLive(), _reloadFeed()]);
  }

  Future<void> _loadArea() async {
    final data = context.read<AppData>();
    final center = _center!;
    final diet = context.read<Session>().diet;
    final (top, trending, news) = await (
      data.topNearby(center.latitude, center.longitude, diet).catchError((_) => _top),
      data.trending(center.latitude, center.longitude).catchError((_) => _trending),
      data.newPlaces(center.latitude, center.longitude).catchError((_) => _news),
    ).wait;
    if (!mounted) return;
    setState(() {
      _top = top;
      _trending = trending;
      _news = news;
      _areaLoaded = true;
    });
  }

  Future<void> _loadLive() async {
    try {
      final json = await context.read<Session>().api.get('/feed/live') as List;
      if (mounted) setState(() => _live = [for (final l in json) LiveStatusDto.fromJson(l as Map<String, dynamic>)]);
    } catch (_) {
      // Live status is a nice-to-have.
    }
  }

  Future<void> _reloadFeed() {
    _feedGeneration++;
    _items.clear();
    _cursor = null;
    _hasMore = true;
    _loading = false;
    return _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    final generation = _feedGeneration;
    final center = _center!;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Without a position the server sends friends only.
      final json = await context.read<Session>().api.get('/feed', query: {
        'limit': '20',
        'cursor': ?_cursor,
        if (!_friendsOnly) ...{'lat': '${center.latitude}', 'lon': '${center.longitude}'},
      });
      if (generation != _feedGeneration) return;
      final page = FeedPage.fromJson(json as Map<String, dynamic>);
      _items.addAll(page.items);
      _cursor = page.cursor;
      _hasMore = page.hasMore;
    } on ApiException catch (e) {
      if (generation == _feedGeneration) _error = e.message;
    } on OfflineException catch (e) {
      if (generation == _feedGeneration) _error = e.toString();
    } finally {
      if (mounted && generation == _feedGeneration) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final user = session.user!;
    final diet = session.diet;
    final position = context.watch<LocationService>().position;
    final data = context.watch<AppData>();
    final friends = context.watch<Friends>();

    final center = _center;
    final moved = position != null &&
        (center == null ||
            Geolocator.distanceBetween(center.latitude, center.longitude, position.latitude, position.longitude) >
                _reloadDistance);
    // Top places depend on the diet, so a new one loads them again.
    if (_loadedFor != '${user.id}/${diet.name}' || moved) {
      _loadedFor = '${user.id}/${diet.name}';
      _center = position ?? fallbackLocation;
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }

    // The apps remind with a notification, the browser can't.
    final due = kIsWeb ? data.reviewDue(DateTime.now()) : null;
    final duePlace = due == null ? null : data.places[due.dto.placeId];
    final dueText = duePlace == null ? null : reminderText(duePlace.name, data.reviews[duePlace.placeId]?.dto.headline(diet));
    final tasks = [
      if (duePlace != null)
        _Task(
          icon: Icons.rate_review_outlined,
          title: dueText!.$1,
          message: dueText.$2,
          onTap: () => showAppSheet(context, (_) => ReviewSheet(place: duePlace)),
          onClose: () => data.dismissReviewDue(due!),
        ),
      if (data.reviews.isEmpty)
        _Task(
          icon: Icons.restaurant,
          title: 'Bewerte deinen Stammladen',
          message: switch (diet) {
            Diet.all => 'Such ihn auf der Karte und gib Soße, Fleisch und Brot eine Note.',
            Diet.vegetarian => 'Such ihn auf der Karte und bewerte Falafel, Halloumi, Soße und Brot.',
            Diet.vegan => 'Such ihn auf der Karte und bewerte, was es dort Veganes gibt.',
          },
          onTap: widget.onOpenMap,
        ),
      if (friends.accepted.isEmpty)
        _Task(
          icon: Icons.qr_code_2,
          title: 'Hol deine Freunde per QR-Code',
          message: 'Dann siehst du, wo sie gerade Döner essen.',
          onTap: () => showAppSheet(context, (_) => const InviteSheet()),
        ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [BrandTile(size: 30), SizedBox(width: 10), Text('Döner App')]),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.extentAfter < 400) _loadMore();
            return false;
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_live.isNotEmpty) ...[
                SizedBox(
                  height: 96,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _live.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, i) => SizedBox(width: 170, child: _LiveChip(status: _live[i])),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              for (final task in tasks) Padding(padding: const EdgeInsets.only(bottom: 10), child: task),
              if (_news.opened.isNotEmpty || _news.upcoming.isNotEmpty) ...[
                _NewPlacesCard(news: _news),
                const SizedBox(height: 10),
              ],
              if (tasks.isNotEmpty) const SizedBox(height: 10),
              SectionTitle(
                title: switch (diet) { Diet.all => 'Top 3 hier', Diet.vegetarian => 'Top 3 ohne Fleisch', Diet.vegan => 'Top 3 vegan' },
                trailing: position == null
                    ? Text('Freiburg', style: TextStyle(color: Theme.of(context).colorScheme.outline))
                    : null,
              ),
              if (!_areaLoaded)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
              else if (_top.isEmpty)
                GlassCard(
                  onTap: widget.onOpenMap,
                  child: const Text('Hier kennt die App noch keine Döner-Läden. Schau auf der Karte, was es in der Nähe gibt.'),
                )
              else ...[
                const Divider(),
                for (final (i, place) in _top.indexed) _TopTile(rank: i + 1, place: place, diet: diet),
              ],
              if (_trending.where((p) => diet != Diet.vegan || p.veganOptions != false).toList() case final trending
                  when trending.isNotEmpty) ...[
                const SizedBox(height: 24),
                const SectionTitle(title: 'Gerade im Trend'),
                SizedBox(
                  height: 118,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: trending.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) => SizedBox(width: 170, child: _PlaceCard(place: trending[i], diet: diet)),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              SectionTitle(
                title: _friendsOnly ? 'Deine Freunde' : 'In deiner Gegend',
                trailing: FilterChip(
                  label: const Text('Nur Freunde'),
                  selected: _friendsOnly,
                  onSelected: (value) {
                    setState(() => _friendsOnly = value);
                    _reloadFeed();
                  },
                ),
              ),
              if (_items.isNotEmpty) const Divider(),
              for (final item in _items)
                ActivityCard(
                    type: item.type,
                    title: item.user.displayName,
                    subtitle: '${item.type == FeedItemType.visit ? 'Eingecheckt bei' : 'Bewertet:'} ${item.place.name}',
                    timestamp: item.timestamp,
                    score: item.headline(diet),
                    ratings: item.ratings,
                    diet: diet,
                    text: item.text,
                    foodType: item.foodType,
                    photoId: item.photoId,
                    onSite: item.onSite,
                    highlight: item.fromFriend,
                  onTap: () => showPlaceDetail(context, item.place),
                ),
              if (_loading)
                const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
              else if (_error != null && _items.isEmpty)
                EmptyState(
                  icon: Icons.cloud_off,
                  title: 'Nicht geladen',
                  message: _error!,
                  action: OutlinedButton(onPressed: _reloadFeed, child: const Text('Erneut versuchen')),
                )
              else if (_items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    _friendsOnly
                        ? 'Deine Freunde haben noch nichts eingecheckt oder bewertet.'
                        : 'In deiner Gegend hat noch niemand bewertet. Fang du an!',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Theme.of(context).colorScheme.outline),
                  ),
                ),
              const GoogleAttribution(),
            ],
          ),
        ),
      ),
    );
  }
}

class _Task extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final VoidCallback onTap;
  final VoidCallback? onClose;
  const _Task({required this.icon, required this.title, required this.message, required this.onTap, this.onClose});

  @override
  Widget build(BuildContext context) => GlassCard(
        onTap: onTap,
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Row(
          children: [
            Icon(icon, color: context.accent, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(message, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            if (onClose != null)
              IconButton(icon: const Icon(Icons.close), tooltip: 'Ausblenden', onPressed: onClose)
            else
              const Icon(Icons.chevron_right),
          ],
        ),
      );
}

class _TopTile extends StatelessWidget {
  final int rank;
  final PlaceDto place;
  final Diet diet;
  const _TopTile({required this.rank, required this.place, required this.diet});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final score = place.score(diet);
    return HairlineRow(
      onTap: () => showPlaceDetail(context, place),
      child: Row(
        children: [
          RankBadge(rank: rank),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(place.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (place.address != null) Text(place.address!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (score.average == null)
            Text('noch unbewertet', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline))
          else
            ScoreBlock(average: score.average!, count: score.count),
        ],
      ),
    );
  }
}

class _PlaceCard extends StatelessWidget {
  final PlaceDto place;
  final Diet diet;
  const _PlaceCard({required this.place, required this.diet});

  @override
  Widget build(BuildContext context) {
    final score = place.score(diet);
    return GlassCard(
        padding: const EdgeInsets.all(12),
        onTap: () => showPlaceDetail(context, place),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(place.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (place.city != null) Text(place.city!, style: Theme.of(context).textTheme.bodySmall),
            const Spacer(),
            if (score.average != null)
              Row(children: [
                DoenerRating(value: score.average!.round(), size: 12),
                const SizedBox(width: 4),
                Text(formatRating(score.average!), style: numberStyle.copyWith(color: context.accent, fontSize: 15)),
                Text(' (${score.count})', style: Theme.of(context).textTheme.labelSmall),
              ]),
          ],
        ),
      );
  }
}

/// Places that opened lately around, and openings Google announced.
class _NewPlacesCard extends StatelessWidget {
  final NewPlacesDto news;
  const _NewPlacesCard({required this.news});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final city = (news.opened.isEmpty ? news.upcoming : news.opened).first.city;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('🎉 Neu in ${city ?? 'der Gegend'}', style: const TextStyle(fontWeight: FontWeight.w600)),
          for (final place in news.opened)
            InkWell(
              onTap: () => showPlaceDetail(context, place),
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${place.name} hat am ${formatDay(place.openedOn!)} aufgemacht'),
                          if (place.address != null) Text(place.address!, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
              ),
            ),
          for (final place in news.upcoming)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '🗓️ Bald: ${place.name}${place.address == null ? '' : ', ${place.address}'}'
                '${place.opensOn == null ? '' : '. Laut Google ${formatOpening(place.opensOn!)}'}',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _LiveChip extends StatelessWidget {
  final LiveStatusDto status;
  const _LiveChip({required this.status});

  @override
  Widget build(BuildContext context) => GlassCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(status.user.displayName, style: TextStyle(fontWeight: FontWeight.w600, color: context.accent)),
            Text('isst gerade bei ${status.placeName}', maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
            if (FoodItem.byId(status.foodType) case final food?) Text('${food.emoji} ${food.label}', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
}
