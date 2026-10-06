import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:doener_models/doener_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:provider/provider.dart';
import 'package:sembast/sembast.dart';

import 'core/api.dart';
import 'core/app_data.dart';
import 'core/location.dart';
import 'core/reminders.dart';
import 'core/session.dart';
import 'features/auth/login_screen.dart';
import 'features/map/map_screen.dart';
import 'features/onboarding/welcome_screen.dart';
import 'features/place/check_in_sheet.dart';
import 'features/place/review_sheet.dart';
import 'features/profile/profile_screen.dart';
import 'features/ranking/ranking_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/social/friends.dart';
import 'features/social/invite.dart';
import 'features/start/start_screen.dart';
import 'ui/widgets.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

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
        navigatorKey: _navigatorKey,
        title: 'Döner App',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => _FeedbackButton(child: child!),
        home: _Root(
          onboardingDone: onboardingDone,
          invitePromptDone: invitePromptDone,
          linkToken: linkToken,
          inviteCode: inviteCode,
          links: links,
        ),
      );
}

/// Test phase: a bug button over every screen, sheets included. It takes a
/// screenshot of what is below it and opens the feedback form with it.
/// Drag it aside when it covers something.
class _FeedbackButton extends StatefulWidget {
  final Widget child;
  const _FeedbackButton({required this.child});

  @override
  State<_FeedbackButton> createState() => _FeedbackButtonState();
}

class _FeedbackButtonState extends State<_FeedbackButton> {
  static const _size = 40.0;
  final _screen = GlobalKey();
  Offset? _position;
  bool _open = false;

  /// Without the Google map: Flutter can't capture native views.
  Future<Uint8List?> _screenshot() async {
    try {
      final boundary = _screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: min(MediaQuery.devicePixelRatioOf(context), 2));
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return png?.buffer.asUint8List();
    } catch (e) {
      debugPrint('Screenshot failed: $e'); // the report still goes out, just without it
      return null;
    }
  }

  Future<void> _report() async {
    if (_open) return;
    setState(() => _open = true);
    final screenshot = await _screenshot();
    if (!mounted) return;
    await showAppSheet(_navigatorKey.currentContext!, (_) => FeedbackSheet(screenshot: screenshot));
    if (mounted) setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = context.select<Session, bool>((s) => s.isLoggedIn);
    return LayoutBuilder(builder: (context, constraints) {
      final padding = MediaQuery.paddingOf(context);
      final position = _position ?? Offset(constraints.maxWidth - _size - 8, constraints.maxHeight * 0.6);
      final left = clampDouble(position.dx, 0, max(0.0, constraints.maxWidth - _size));
      final top = clampDouble(position.dy, padding.top, max(padding.top, constraints.maxHeight - _size - padding.bottom));
      return Stack(
        children: [
          RepaintBoundary(key: _screen, child: widget.child),
          if (loggedIn && !_open)
            Positioned(
              left: left,
              top: top,
              // On the web the map is a DOM element and would take the taps.
              child: PointerInterceptor(
                intercepting: kIsWeb,
                child: GestureDetector(
                  onPanUpdate: (details) => setState(() => _position = Offset(left, top) + details.delta),
                  child: Opacity(
                    opacity: 0.85,
                    child: FloatingActionButton.small(
                      heroTag: null,
                      onPressed: _report,
                      child: const Icon(Icons.bug_report_outlined, semanticLabel: 'Fehler melden'),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }
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
  late final Reminders? _reminders = context.read<Reminders?>();
  LatLng? _loadedAround;

  @override
  void initState() {
    super.initState();
    _location.addListener(_loadAround);
    _loadAround();
    // A reminder may have started the app.
    _reminders?.opened.addListener(_openReminder);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openReminder());
  }

  @override
  void dispose() {
    _location.removeListener(_loadAround);
    _reminders?.opened.removeListener(_openReminder);
    super.dispose();
  }

  /// A tapped reminder opens the review of its place.
  void _openReminder() {
    final placeId = _reminders?.opened.value;
    if (placeId == null || !mounted) return;
    _reminders!.opened.value = null;
    final place = context.read<AppData>().places[placeId];
    if (place != null) showAppSheet(context, (_) => ReviewSheet(place: place));
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
    // Browsers on a desktop get a rail on the left and a column of readable width.
    final wide = MediaQuery.sizeOf(context).width >= 900;
    Widget column(Widget child) => wide ? Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: child)) : child;
    final checkIn = GradientCircle(
      size: 44,
      active: onSite,
      child: Opacity(opacity: onSite ? 1 : 0.4, child: const Text('🥙', style: TextStyle(fontSize: 22))),
    );
    final profileIcon = Badge(isLabelVisible: pending > 0, label: Text('$pending'), child: const Icon(Icons.account_circle_outlined));
    final destinations = [
      (icon: const Icon(Icons.home_outlined), selected: const Icon(Icons.home), label: 'Start'),
      (icon: const Icon(Icons.emoji_events_outlined), selected: const Icon(Icons.emoji_events), label: 'Ranking'),
      (icon: checkIn, selected: checkIn, label: 'Einchecken'),
      (icon: const Icon(Icons.map_outlined), selected: const Icon(Icons.map), label: 'Karte'),
      (icon: profileIcon, selected: const Icon(Icons.account_circle), label: 'Profil'),
    ];
    void select(int i) => i == _checkInTab ? _checkIn() : setState(() => _tab = i);
    final body = IndexedStack(
      index: _tab < _checkInTab ? _tab : _tab - 1,
      children: [
        column(StartScreen(onOpenMap: () => setState(() => _tab = _mapTab))),
        column(const RankingScreen()),
        const MapScreen(),
        column(const ProfileScreen()),
      ],
    );
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _tab,
              onDestinationSelected: select,
              labelType: NavigationRailLabelType.all,
              minWidth: 96,
              leading: const Padding(
                padding: EdgeInsets.only(top: 8, bottom: 20),
                child: Column(children: [BrandTile(), SizedBox(height: 6), Text('Döner', style: displayStyle)]),
              ),
              destinations: [
                for (final (i, d) in destinations.indexed)
                  NavigationRailDestination(
                    icon: d.icon,
                    selectedIcon: i == _checkInTab ? d.selected : ActiveTabMark(icon: d.selected),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).dividerColor))),
        child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: select,
          destinations: [
            for (final (i, d) in destinations.indexed)
              NavigationDestination(
                icon: d.icon,
                selectedIcon: i == _checkInTab ? d.selected : ActiveTabMark(icon: d.selected),
                label: d.label,
              ),
          ],
        ),
      ),
    );
  }
}
