import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/app_data.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';
import '../place/place_detail.dart';
import '../social/friends.dart';
import '../social/moderation.dart';
import '../social/reactions.dart';

Future<void> showUserProfile(BuildContext context, UserDto user) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => UserProfileScreen(user: user)));

Future<void> _openPlace(BuildContext context, String placeId) async {
  try {
    final place = await context.read<AppData>().place(placeId);
    if (context.mounted) await showPlaceDetail(context, place);
  } on OfflineException catch (e) {
    if (context.mounted) showMessage(context, e.toString());
  } on ApiException catch (e) {
    if (context.mounted) showMessage(context, e.message);
  }
}

/// Name, tier and numbers. [checkIns] only for friends and oneself, [friends] and the
/// progress to the next tier only on the own profile.
class ProfileHeader extends StatelessWidget {
  final String name;
  final int reviewedPlaces;
  final DateTime? since;
  final int? checkIns;
  final int? friends;
  final bool own;
  const ProfileHeader({super.key, required this.name, required this.reviewedPlaces, this.since, this.checkIns, this.friends, this.own = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tier = Tier.forReviewedPlaces(reviewedPlaces);
    final next = tier.next;
    Widget stat(int value, String label) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            Text('$value', style: numberStyle.copyWith(fontSize: 32, color: theme.colorScheme.onSurface)),
            const SizedBox(height: 4),
            Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: tileColor, borderRadius: BorderRadius.circular(18)),
              child: Text(name.characters.first.toUpperCase(), style: displayStyle.copyWith(fontSize: 32, color: accentFor(Brightness.dark))),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: displayStyle.copyWith(fontSize: 28, color: theme.colorScheme.onSurface)),
                  Text(
                    tier.displayName,
                    style: TextStyle(color: context.accent, fontWeight: FontWeight.w600),
                  ),
                  if (since != null)
                    Text(
                      'Seit ${DateFormat('MMMM y', 'de').format(since!.toLocal())}',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Semantics(
          label: 'Stufe ${tier.index + 1} von ${Tier.values.length}',
          child: Row(
            children: [
              for (final t in Tier.values) ...[
                if (t.index > 0) const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    height: 8,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      gradient: t.index <= tier.index ? actionGradient : null,
                      color: t.index <= tier.index ? null : theme.colorScheme.onSurface.withValues(alpha: 0.1),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (own && next != null) ...[
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Noch '),
                TextSpan(
                  text: next.reviewedPlaces - reviewedPlaces == 1 ? '1 Laden' : '${next.reviewedPlaces - reviewedPlaces} Läden',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const TextSpan(text: ' bewerten bis '),
                TextSpan(
                  text: next.displayName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        const Divider(height: 1),
        IntrinsicHeight(
          child: Row(
            children: [
              stat(reviewedPlaces, 'Läden bewertet'),
              if (checkIns != null) ...[const VerticalDivider(width: 1), stat(checkIns!, 'Check-ins')],
              if (friends != null) ...[const VerticalDivider(width: 1), stat(friends!, 'Freunde')],
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

/// "Top 5", reviews and check-ins of a profile. [visits] null: only friends see them.
class ProfileTabs extends StatefulWidget {
  final UserDto user;
  final List<LocalReview> reviews;
  final List<LocalVisit>? visits;
  final bool own;
  final VoidCallback? onBlocked;
  const ProfileTabs({super.key, required this.user, required this.reviews, this.visits, this.own = false, this.onBlocked});

  @override
  State<ProfileTabs> createState() => _ProfileTabsState();
}

class _ProfileTabsState extends State<ProfileTabs> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final diet = context.watch<Session>().diet;
    final visits = widget.visits;
    final top = [
      for (final r in widget.reviews)
        if (r.dto.headline(diet) case final score?) (review: r.dto, score: score),
    ]..sort((a, b) => b.score.compareTo(a.score));
    final tabs = ['Top 5', 'Bewertungen ${widget.reviews.length}', visits == null ? 'Check-ins 🔒' : 'Check-ins ${visits.length}'];

    Widget empty(String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(text, style: TextStyle(color: theme.colorScheme.outline)),
    );

    final content = switch (_tab) {
      0 when top.isEmpty => [
        empty(switch ((widget.own, widget.reviews.isEmpty)) {
          (true, true) => 'Bewerte Läden, dann steht hier deine Bestenliste.',
          (false, true) => 'Noch keine Bewertungen.',
          // Scores follow the viewer's diet, like everywhere in the app.
          _ => 'Keine Bewertung passt zu deiner Ernährung.',
        }),
      ],
      0 => [
        for (final (i, t) in top.take(5).indexed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: SizedBox(
              width: 32,
              child: Text(
                '${i + 1}',
                textAlign: TextAlign.center,
                style: numberStyle.copyWith(fontSize: 26, color: theme.colorScheme.onSurface),
              ),
            ),
            title: Text(t.review.placeName, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: t.review.ratings.isEmpty
                ? null
                : Text(
                    [
                      for (final e in t.review.ratings.entries)
                        if (diet.allows(e.key.diet)) '${e.key.label} ${formatRating(e.value)}',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                  ),
            trailing: Text(formatRating(t.score), style: numberStyle.copyWith(fontSize: 24, color: theme.colorScheme.onSurface)),
            onTap: () => _openPlace(context, t.review.placeId),
          ),
      ],
      1 when widget.reviews.isEmpty => [empty('Noch keine Bewertungen.')],
      1 => [
        for (final r in widget.reviews)
          ActivityCard(
            type: FeedItemType.review,
            title: r.dto.placeName,
            timestamp: r.dto.updatedAt,
            score: r.dto.headline(diet),
            ratings: r.dto.ratings,
            diet: diet,
            text: r.dto.text,
            photoId: r.dto.photoId,
            photo: r.photo,
            onSite: r.dto.onSite,
            regular: r.dto.regular,
            pending: r.pending,
            footer: r.dto.reactions.isEmpty ? null : ReactionBar(reactions: r.dto.reactions),
            onTap: () => _openPlace(context, r.dto.placeId),
            menu: widget.own ? null : ContentMenu(user: widget.user, reviewId: r.dto.id, onBlocked: widget.onBlocked ?? () {}),
          ),
      ],
      _ when visits == null => [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: [
              Icon(Icons.lock_outline, color: theme.colorScheme.outline),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Check-ins von ${widget.user.displayName} sehen nur Freunde.', style: TextStyle(color: theme.colorScheme.outline)),
              ),
            ],
          ),
        ),
      ],
      _ when visits.isEmpty => [empty('Noch keine Check-ins.')],
      _ => [
        for (final v in visits)
          ActivityCard(
            type: FeedItemType.visit,
            title: v.dto.placeName,
            subtitle: FoodItem.byId(v.dto.foodType)?.label,
            timestamp: v.dto.visitedAt,
            foodType: v.dto.foodType,
            pending: v.pending,
            footer: v.dto.reactions.isEmpty ? null : ReactionBar(reactions: v.dto.reactions),
            onTap: () => _openPlace(context, v.dto.placeId),
          ),
      ],
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: [
              for (final (i, label) in tabs.indexed)
                Padding(
                  padding: const EdgeInsets.only(right: 20),
                  child: InkWell(
                    onTap: () => setState(() => _tab = i),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(2, 12, 2, 10),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(width: 2, color: i == _tab ? context.accent : Colors.transparent)),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(fontWeight: FontWeight.w600, color: i == _tab ? theme.colorScheme.onSurface : theme.colorScheme.outline),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        ...content,
      ],
    );
  }
}

/// Someone else's profile, as everyone sees it; friends see the check-ins too.
class UserProfileScreen extends StatefulWidget {
  final UserDto user;
  const UserProfileScreen({super.key, required this.user});

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  ProfileDto? _profile;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final json = await context.read<Session>().api.get('/users/${widget.user.id}/profile');
      if (mounted) setState(() => _profile = ProfileDto.fromJson(json as Map<String, dynamic>));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _blocked() => Navigator.of(context).pop();

  Widget _friendButton(Friends friends) {
    FriendshipDto? friendship;
    for (final f in friends.all) {
      if (f.user.id == widget.user.id) friendship = f;
    }
    return switch (friendship) {
      FriendshipDto(status: FriendshipStatus.accepted) => OutlinedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.group),
        label: const Text('Befreundet'),
      ),
      FriendshipDto(direction: FriendshipDirection.outgoing) => const OutlinedButton(onPressed: null, child: Text('Angefragt')),
      final FriendshipDto f => FilledButton(
        onPressed: () async {
          await friends.accept(f.id);
          await _load();
        },
        child: const Text('Anfrage annehmen'),
      ),
      null => FilledButton(onPressed: () => friends.request(widget.user.id), child: const Text('Als Freund hinzufügen')),
    };
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final own = widget.user.id == context.watch<Session>().user?.id;
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (!own)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ContentMenu(user: widget.user, onBlocked: _blocked, small: false),
            ),
        ],
      ),
      body: profile == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : EmptyState(icon: Icons.person_off_outlined, title: 'Profil nicht geladen', message: _error!),
            )
          // As wide as the tabs of the app shell on the desktop.
          : RefreshIndicator(
              onRefresh: _load,
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                    children: [
                      ProfileHeader(
                        name: profile.user.displayName,
                        reviewedPlaces: profile.user.reviewedPlaces,
                        since: profile.since,
                        checkIns: profile.checkIns,
                      ),
                      if (!own) ...[const SizedBox(height: 12), _friendButton(context.watch<Friends>())],
                      ProfileTabs(
                        user: profile.user,
                        own: own,
                        reviews: [for (final r in profile.reviews) LocalReview(r)],
                        visits: profile.visits?.map(LocalVisit.new).toList(),
                        onBlocked: _blocked,
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
