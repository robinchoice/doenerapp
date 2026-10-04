import 'dart:async';

import 'package:doener_models/doener_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'package:sembast/sembast.dart';

import 'core/api.dart';
import 'core/app_data.dart';
import 'core/location.dart';
import 'core/session.dart';
import 'features/auth/login_screen.dart';
import 'features/map/map_screen.dart';
import 'features/onboarding/welcome_screen.dart';
import 'features/place/check_in_sheet.dart';
import 'features/profile/profile_screen.dart';
import 'features/ranking/ranking_screen.dart';
import 'features/social/friends.dart';
import 'features/social/invite.dart';
import 'features/start/start_screen.dart';
import 'ui/widgets.dart';

class DoenerApp extends StatelessWidget {
  final bool onboardingDone;
  final bool invitePromptDone;

  /// Magic-link token from the URL (web only).
  final String? linkToken;

  /// Invite link that brought the user here and is not accepted yet.
  final String? inviteCode;

  /// Links that open the installed app (`https://…/i/<code>`), the one it
  /// was started with included.
  final Stream<Uri>? links;

  const DoenerApp({super.key, required this.onboardingDone, required this.invitePromptDone, this.linkToken, this.inviteCode, this.links});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Döner App',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: _Root(
          onboardingDone: onboardingDone,
          invitePromptDone: invitePromptDone,
          linkToken: linkToken,
          inviteCode: inviteCode,
          links: links,
        ),
      );
}

class _Root extends StatefulWidget {
  final bool onboardingDone;
  final bool invitePromptDone;
  final String? linkToken;
  final String? inviteCode;
  final Stream<Uri>? links;
  const _Root({required this.onboardingDone, required this.invitePromptDone, this.linkToken, this.inviteCode, this.links});

  @override
  State<_Root> createState() => _RootState();
}

/// Onboarding, then login and a chosen name — the app needs an account.
/// Afterwards a pending invite is accepted and the user is asked once to
/// invite their own friends.
class _RootState extends State<_Root> {
  late bool _onboardingDone = widget.onboardingDone;
  late bool _invitePromptDone = widget.invitePromptDone;
  late String? _inviteCode = widget.inviteCode;
  bool _acceptingInvite = false;
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<Uri>? _links;

  @override
  void initState() {
    super.initState();
    _links = widget.links?.listen(_openLink);
    final data = context.read<AppData>();
    final location = context.read<LocationService>();
    _lifecycle = AppLifecycleListener(onResume: () {
      data.sync();
      data.refreshMine();
      // Back at the shop? The check-in button needs a fresh position.
      if (_onboardingDone) location.request(ask: false);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Keep login token and invite code out of the browser's address bar.
      if (kIsWeb && Uri.base.hasQuery) SystemNavigator.routeInformationUpdated(uri: Uri.parse('/'));
      final token = widget.linkToken;
      if (token != null) await completeLinkLogin(context, token, inviteCode: _inviteCode);
      if (mounted && _onboardingDone) context.read<LocationService>().request();
    });
  }

  @override
  void dispose() {
    _links?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  /// An invite link opened in the app counts like one opened in the browser:
  /// kept until the login, accepted once the account has a name.
  Future<void> _openLink(Uri link) async {
    final segments = link.pathSegments;
    if (segments.length != 2 || segments.first != 'i') return;
    await pendingInviteRecord.put(context.read<Database>(), segments.last);
    if (mounted) setState(() => _inviteCode = segments.last);
  }

  Future<void> _finishOnboarding() async {
    await settingsStore.record('onboardingDone').put(context.read<Database>(), true);
    setState(() => _onboardingDone = true);
  }

  Future<void> _finishInvitePrompt() async {
    await settingsStore.record('invitePromptDone').put(context.read<Database>(), true);
    setState(() => _invitePromptDone = true);
  }

  /// Offline (or on a server error) the invite stays pending for the next try;
  /// a reset link or the user's own link is dropped.
  Future<void> _acceptInvite(String code) async {
    if (_acceptingInvite) return;
    _acceptingInvite = true;
    final friends = context.read<Friends>();
    final db = context.read<Database>();
    try {
      final friendship = await friends.acceptInvite(code);
      if (mounted) showMessage(context, 'Du bist jetzt mit ${friendship.user.displayName} befreundet.');
    } on ApiException catch (e) {
      if (e.status != 400 && e.status != 404) return;
      if (mounted) showMessage(context, e.message);
    } on OfflineException {
      return;
    } finally {
      _acceptingInvite = false;
    }
    _inviteCode = null;
    await pendingInviteRecord.delete(db);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    if (!_onboardingDone) return WelcomeScreen(onDone: _finishOnboarding, inviteCode: _inviteCode);
    if (!session.isLoggedIn) {
      // Logged out or session expired: screens opened during the old session go away.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      });
      return LoginScreen(inviteCode: _inviteCode);
    }
    if (Validation.isGeneratedName(session.user!.displayName)) return const ChooseNameScreen();
    // Accepted only now, so the inviter's new friend shows up with a real name.
    final code = _inviteCode;
    if (code != null) WidgetsBinding.instance.addPostFrameCallback((_) => _acceptInvite(code));
    if (!_invitePromptDone) return InviteStepScreen(onDone: _finishInvitePrompt);
    return const HomeShell();
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// Start · Ranking · 🥙 · Karte · Profil. The middle button is no tab: it
/// checks in at the shop the user is standing at and is grey anywhere else.
class _HomeShellState extends State<HomeShell> {
  static const _checkInTab = 2;
  static const _mapTab = 3;
  int _tab = 0;
  late final LocationService _location = context.read<LocationService>();
  LatLng? _loadedAround;

  @override
  void initState() {
    super.initState();
    _location.addListener(_loadAround);
    _loadAround();
  }

  @override
  void dispose() {
    _location.removeListener(_loadAround);
    super.dispose();
  }

  List<PlaceDto> _nearby(AppData data) {
    final position = _location.position;
    return position == null ? const [] : data.placesWithin(position.latitude, position.longitude, checkInRadius);
  }

  /// Keeps the shops next to the user loaded — they decide whether the
  /// check-in button is active.
  Future<void> _loadAround({bool force = false}) async {
    final position = _location.position;
    final last = _loadedAround;
    if (position == null || !mounted) return;
    if (!force &&
        last != null &&
        Geolocator.distanceBetween(last.latitude, last.longitude, position.latitude, position.longitude) < 100) {
      return;
    }
    _loadedAround = position;
    try {
      await context.read<AppData>().loadAround(position.latitude, position.longitude);
    } on OfflineException {
      _loadedAround = null; // shops cached earlier still count
    } on ApiException {
      _loadedAround = null;
    }
  }

  Future<void> _checkIn() async {
    final data = context.read<AppData>();
    if (_nearby(data).isEmpty) {
      // Before saying no: ask for the location if it was never granted, and
      // reload the shops around in case that failed earlier.
      await _location.request();
      await _loadAround(force: true);
    }
    if (!mounted) return;
    final nearby = _nearby(data);
    if (nearby.isEmpty) {
      return showMessage(
        context,
        _location.position == null
            ? 'Zum Einchecken braucht die App deinen Standort.'
            : 'Einchecken geht nur vor Ort – in ${checkInRadius.round()} m ist kein Döner-Laden.',
      );
    }
    await showAppSheet(context, (_) => CheckInSheet(places: nearby));
  }

  @override
  Widget build(BuildContext context) {
    final pending = context.select<AppData, int>((d) => d.pendingCount);
    context.watch<LocationService>();
    final onSite = context.select<AppData, bool>((d) => _nearby(d).isNotEmpty);
    return Scaffold(
      body: IndexedStack(
        index: _tab < _checkInTab ? _tab : _tab - 1,
        children: [
          StartScreen(onOpenMap: () => setState(() => _tab = _mapTab)),
          const RankingScreen(),
          const MapScreen(),
          const ProfileScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => i == _checkInTab ? _checkIn() : setState(() => _tab = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Start'),
          const NavigationDestination(icon: Icon(Icons.emoji_events_outlined), selectedIcon: Icon(Icons.emoji_events), label: 'Ranking'),
          NavigationDestination(
            icon: CircleAvatar(
              radius: 22,
              backgroundColor: onSite ? doenerOrange : Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Opacity(opacity: onSite ? 1 : 0.4, child: const Text('🥙', style: TextStyle(fontSize: 22))),
            ),
            label: 'Einchecken',
          ),
          const NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Karte'),
          NavigationDestination(
            icon: Badge(isLabelVisible: pending > 0, label: Text('$pending'), child: const Icon(Icons.account_circle_outlined)),
            selectedIcon: const Icon(Icons.account_circle),
            label: 'Profil',
          ),
        ],
      ),
    );
  }
}
