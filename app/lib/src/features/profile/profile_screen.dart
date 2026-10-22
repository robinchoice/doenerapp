import 'dart:math';

import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/app_data.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';
import '../news/news.dart';
import '../settings/settings_screen.dart';
import '../social/friends.dart';
import '../social/invite.dart';
import 'mine.dart';
import 'profile_view.dart';

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

/// The own profile: what others see, plus progress, friends and settings.
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

    final reviews = data.reviews.values.toList()..sort((a, b) => b.dto.updatedAt.compareTo(a.dto.updatedAt));
    final since = [for (final v in data.visits) v.dto.visitedAt, for (final r in reviews) r.dto.createdAt]
        .fold<DateTime?>(null, (first, d) => first == null || d.isBefore(first) ? d : first);
    final december = DateTime.now().month == DateTime.december;
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
      body: RefreshIndicator(
        onRefresh: () async {
          await data.sync();
          await data.refreshMine();
        },
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ProfileHeader(
                    name: user?.displayName ?? 'Döner-Fan',
                    reviewedPlaces: reviews.length,
                    since: since,
                    checkIns: data.visits.length,
                    friends: friends.accepted.length,
                    own: true,
                  ),
                  const SizedBox(height: 8),
                  _MenuRow(
                    icon: Icons.group,
                    label: 'Freunde',
                    trailing: [
                      if (friends.incoming.isNotEmpty) Badge(backgroundColor: needsGlow, textColor: ink, label: Text('${friends.incoming.length}')),
                      const SizedBox(width: 8),
                      Text('${friends.accepted.length}', style: TextStyle(color: theme.colorScheme.outline)),
                    ],
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FriendsScreen())),
                  ),
                  _MenuRow(icon: Icons.qr_code_2, label: 'Freunde einladen', onTap: () => showAppSheet(context, (_) => const InviteSheet())),
                  if (user?.admin ?? false)
                    _MenuRow(
                      icon: Icons.person_add_alt,
                      label: 'Tester',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _TestersScreen())),
                    ),
                  if (user?.admin ?? false)
                    _MenuRow(
                      icon: Icons.campaign_outlined,
                      label: 'Neuigkeiten',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewsAdminScreen())),
                    ),
                  _MenuRow(
                    icon: Icons.storefront,
                    label: 'Meine Läden',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyPlacesScreen())),
                  ),
                  // The year in review only makes sense at its end.
                  _MenuRow(
                    icon: Icons.auto_awesome,
                    label: 'Döner Wrapped ${DateTime.now().year}',
                    trailing: [
                      if (!december) Text('ab 1. Dezember', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                    ],
                    onTap: december
                        ? () => Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const WrappedScreen()))
                        : null,
                  ),
                  if (user != null)
                    ProfileTabs(
                      user: UserDto(id: user.id, displayName: user.displayName, reviewedPlaces: reviews.length),
                      own: true,
                      reviews: reviews,
                      visits: data.visits,
                    ),
                ],
              ),
            ),
            const PleasanceFooter(),
          ],
        ),
      ),
    );
  }
}



/// Sign-up is closed: admins let testers in — from the requests on the landing
/// page or by address. Each gets an account and a login mail, iPhones also the
/// TestFlight invite.
class _TestersScreen extends StatefulWidget {
  const _TestersScreen();

  @override
  State<_TestersScreen> createState() => _TestersScreenState();
}

class _TestersScreenState extends State<_TestersScreen> {
  final _email = TextEditingController();
  String _platform = 'ios';
  List<TesterRequestDto>? _requests;
  String? _error;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final json = await context.read<Session>().api.get('/tester-requests') as List;
      if (mounted) setState(() => _requests = [for (final r in json) TesterRequestDto.fromJson(r as Map<String, dynamic>)]);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// [key] marks what is running: a request id or the address field.
  Future<void> _run(String key, Future<String> Function() action) async {
    setState(() => _busy.add(key));
    try {
      final message = await action();
      if (mounted) showMessage(context, message);
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  static String _done(String email, InviteResult result) => switch (result.testFlight) {
        'invited' => 'Login-Mail an $email verschickt, die TestFlight-Einladung kommt von Apple',
        'failed' => 'Login-Mail an $email verschickt. TestFlight hat nicht geklappt, bitte in App Store Connect einladen',
        'off' => 'Login-Mail an $email verschickt. TestFlight ist auf dem Server nicht eingerichtet, bitte in App Store Connect einladen',
        _ => 'Login-Mail an $email verschickt',
      };

  Future<void> _letIn(TesterRequestDto request) => _run(request.id, () async {
        final json = await context.read<Session>().api.post('/tester-requests/${request.id}/invite');
        if (mounted) setState(() => _requests?.removeWhere((r) => r.email == request.email));
        return _done(request.email, InviteResult.fromJson(json as Map<String, dynamic>));
      });

  Future<void> _turnDown(TesterRequestDto request) => _run(request.id, () async {
        await context.read<Session>().api.delete('/tester-requests/${request.id}');
        if (mounted) setState(() => _requests?.remove(request));
        return 'Anfrage von ${request.email} gelöscht';
      });

  Future<void> _invite() {
    final email = Validation.normalizeEmail(_email.text);
    return _run('address', () async {
      final json = await context.read<Session>().api.post('/auth/invite', InviteRequest(email: email, platform: _platform).toJson());
      _email.clear();
      if (mounted) setState(() => _requests?.removeWhere((r) => r.email == email));
      return _done(email, InviteResult.fromJson(json as Map<String, dynamic>));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final requests = _requests;
    return Scaffold(
      appBar: AppBar(title: const Text('Tester')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          // A column of readable width on the desktop, like the profile.
          padding: EdgeInsets.symmetric(vertical: 16, horizontal: max(16, (MediaQuery.sizeOf(context).width - 720) / 2)),
          children: [
            SectionTitle(title: requests == null || requests.isEmpty ? 'Bewerbungen' : 'Bewerbungen (${requests.length})'),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error))
            else if (requests == null)
              const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
            else if (requests.isEmpty)
              Text('Gerade bewirbt sich niemand. Die Bewerbung steht auf der Landingpage.', style: TextStyle(color: theme.colorScheme.outline))
            else
              // The address gets the full width: Robin has to see whom he lets in.
              for (final r in requests)
                HairlineRow(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(r.platform == 'ios' ? Icons.phone_iphone : Icons.android, color: context.accent, size: 20),
                        const SizedBox(width: 8),
                        Expanded(child: Text(r.email, style: const TextStyle(fontWeight: FontWeight.w600))),
                      ]),
                      const SizedBox(height: 2),
                      Text(
                        [r.platform == 'ios' ? 'iPhone' : 'Android', formatDate(r.createdAt), if (r.invitedBy != null) 'über ${r.invitedBy}']
                            .join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (_busy.contains(r.id))
                            const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          else ...[
                            TextButton(onPressed: () => _turnDown(r), child: const Text('Ablehnen')),
                            const SizedBox(width: 8),
                            FilledButton(onPressed: () => _letIn(r), child: const Text('Freischalten')),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: 28),
            const SectionTitle(title: 'Per Adresse einladen'),
            Text('Legt das Konto an und schickt einen Login-Code, bei iPhone auch die TestFlight-Einladung.',
                style: TextStyle(color: theme.colorScheme.outline)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              for (final (value, label) in const [('ios', 'iPhone'), ('android', 'Android'), ('web', 'Nur Web')])
                ChoiceChip(label: Text(label), selected: _platform == value, onSelected: (_) => setState(() => _platform = value)),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'E-Mail', prefixIcon: Icon(Icons.mail_outline)),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy.contains('address') || !Validation.isValidEmail(_email.text) ? null : _invite,
              child: const Text('Einladen'),
            ),
          ],
        ),
      ),
    );
  }
}


class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final List<Widget> trailing;

  /// Null greys the row out.
  final VoidCallback? onTap;
  const _MenuRow({required this.icon, required this.label, this.trailing = const [], required this.onTap});

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
        child: Row(children: [
          Icon(icon, color: onTap == null ? outline : context.accent, size: 22),
          const SizedBox(width: 14),
          Expanded(child: Text(label, style: onTap == null ? TextStyle(color: outline) : null)),
          ...trailing,
          if (onTap != null) Icon(Icons.chevron_right, color: outline),
        ]),
      ),
    );
  }
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
