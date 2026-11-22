import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import 'brand.dart';
import 'dock.dart';

// The dock stays beside the wordmark.
const _signatureWidth = 120.0;

// Icons sit this far above the band, clear of the wordmark
const _lift = 26.0;
const _gap = 8.0;
const _base = 40.0;
// Free spots are smaller than apps
const _free = 0.6;

/// The family band beside the Pleasance wordmark. Tapping it pops the tiles up
/// above it, sliding a finger over them grows them like the macOS Dock, lifting
/// the finger on one or tapping it opens that app.
class AppDock extends StatefulWidget {
  final Future<List<PleasanceApp>> Function() loadApps;
  final ValueChanged<Uri>? openUrl;
  const AppDock({super.key, this.loadApps = loadPleasanceApps, this.openUrl});

  @override
  State<AppDock> createState() => _AppDockState();
}

class _AppDockState extends State<AppDock> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _portal = OverlayPortalController();
  late final _pop = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  List<DockSlot> _slots = const [];
  double? _pointer;
  int _hot = -1;
  bool _wanted = false;
  Future<List<PleasanceApp>>? _loading;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pop.dispose();
    super.dispose();
  }

  // Rotation or a resized window moves the band: place the dock again once the new layout is done.
  // A finger held through it no longer points where it did, lifting it must not launch that app.
  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _portal.isShowing) _cancel();
    });
  }

  bool _isCurrent(PleasanceApp app) => app.url.host == 'doener-api.pleasance.org';

  ({String pleasanceTools, String desktopApp, String youAreHere, String freeSpot}) get _text {
    final en = Localizations.localeOf(context).languageCode == 'en';
    return (pleasanceTools: en ? 'Pleasance apps' : 'Pleasance-Apps', desktopApp: en ? 'Desktop app' : 'Desktop-App',
      youAreHere: en ? 'You are here' : 'Du bist hier', freeSpot: en ? 'Free spot' : 'Freier Platz');
  }

  void _open(Uri url) {
    if (widget.openUrl case final open?) { open(url); } else { launchUrl(url, mode: LaunchMode.externalApplication); }
  }

  Future<void> _key(KeyEvent event) async {
    if (event is! KeyDownEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.escape) { _close(); return; }
    if (_slotAt(_hot)?.app case final app? when event.logicalKey == LogicalKeyboardKey.enter && _portal.isShowing) {
      _launch(app); return;
    }
    await _show();
    if (!mounted || !_portal.isShowing) return;
    final direction = event.logicalKey == LogicalKeyboardKey.arrowLeft ? -1 : 1;
    var next = _hot;
    do { next = (next + direction + _slots.length) % _slots.length; } while (_slots[next].app == null);
    setState(() => _hot = next);
  }

  Future<void> _show() async {
    _wanted = true;
    final List<PleasanceApp> apps;
    try {
      apps = await (_loading ??= widget.loadApps());
    } catch (_) {
      // Offline or no list: the band stays a line, the next tap tries again
      _loading = null;
      return;
    }
    if (!mounted || !_wanted || _portal.isShowing || apps.isEmpty) return;
    setState(() {
      _slots = dockSlots(apps);
      _pointer = null;
      _hot = -1;
    });
    _portal.show();
    if (MediaQuery.of(context).disableAnimations) {
      _pop.value = 1;
    } else {
      _pop.forward(from: 0);
    }
  }

  void _close() {
    _wanted = false;
    if (!_portal.isShowing) return;
    _portal.hide();
    setState(() {
      _pointer = null;
      _hot = -1;
    });
  }

  void _launch(PleasanceApp app) {
    _close();
    if (!_isCurrent(app)) _open(app.url);
  }

  RenderBox? get _overlay => Overlay.of(context).context.findRenderObject() as RenderBox?;

  // Where band and overlay are, in the overlay's coordinates
  ({Rect band, Size area})? _geometry() {
    final band = context.findRenderObject() as RenderBox?;
    final overlay = _overlay;
    if (band == null || overlay == null || !band.hasSize || !overlay.hasSize) return null;
    final topLeft = band.localToGlobal(Offset.zero, ancestor: overlay);
    return (band: topLeft & band.size, area: overlay.size);
  }

  List<({double left, double size})> _layout(Rect band, Size area) {
    // Smaller tiles on narrow screens, so the row still fits when it grows
    final units = _slots.fold(0.0, (sum, slot) => sum + (slot.app == null ? _free : 1)) + 1.2;
    final base = math.min(_base, (area.width - 16 - _gap * (_slots.length - 1)) / units);
    return dockLayout(
      sizes: [for (final slot in _slots) slot.app == null ? base * _free : base],
      gap: _gap,
      grow: 0.45,
      reach: 2.5,
      center: band.center.dx,
      pointer: _pointer,
      min: 8,
      max: area.width - 8,
    );
  }

  // Bottom edge of the icons
  double _row(Rect band) => band.top + _bandTop - _lift;

  // Index of the icon under the point, only over the icons themselves
  int _hit(Offset point, Rect band, List<({double left, double size})> row) {
    final bottom = _row(band);
    for (var i = 0; i < row.length; i++) {
      final slot = row[i];
      if (point.dy <= bottom + 6 &&
          point.dy >= bottom - slot.size - 6 &&
          point.dx >= slot.left - _gap / 2 &&
          point.dx <= slot.left + slot.size + _gap / 2) {
        return i;
      }
    }
    return -1;
  }

  void _track(Offset global) {
    final overlay = _overlay;
    final geometry = _geometry();
    if (overlay == null || geometry == null || !_portal.isShowing) return;
    final local = overlay.globalToLocal(global);
    _pointer = local.dx;
    final row = _layout(geometry.band, geometry.area);
    setState(() => _hot = _hit(local, geometry.band, row));
  }

  void _hover(Offset global) {
    _track(global);
    final geometry = _geometry();
    final overlay = _overlay;
    if (geometry == null || overlay == null) return;
    final row = _layout(geometry.band, geometry.area);
    final bounds = Rect.fromLTRB(row.first.left - 12, _row(geometry.band) - 150,
      row.last.left + row.last.size + 12, geometry.band.bottom + 12);
    if (!bounds.contains(overlay.globalToLocal(global))) _close();
  }

  DockSlot? _slotAt(int i) => i >= 0 && i < _slots.length ? _slots[i] : null;

  void _cancel() {
    // A slow first load must not open the dock after the finger has lifted
    if (!_portal.isShowing) _wanted = false;
    setState(() {
      _pointer = null;
      _hot = -1;
    });
  }

  void _release() {
    final app = _slotAt(_hot)?.app;
    if (app != null) {
      _launch(app);
    } else {
      _cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _text;
    final open = _portal.isShowing;
    return Focus(
      onKeyEvent: (_, event) {
        if (![LogicalKeyboardKey.enter, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.escape].contains(event.logicalKey)) {
          return KeyEventResult.ignored;
        }
        _key(event);
        return KeyEventResult.handled;
      },
      child: MouseRegion(onEnter: (_) => _show(), onExit: (_) { if (!_portal.isShowing) _cancel(); }, child: OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _dock,
      child: Semantics(
        button: true,
        expanded: open,
        label: t.pleasanceTools,
        onTap: () => open ? _close() : _show(),
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => open ? _close() : _show(),
          onPanStart: (details) async {
            await _show();
            if (mounted) _track(details.globalPosition);
          },
          onPanUpdate: (details) => _track(details.globalPosition),
          onPanEnd: (_) => _release(),
          onPanCancel: _cancel,
          child: SizedBox(
            width: _signatureWidth,
            height: 32,
            child: _BandLine(open: open),
          ),
        ),
      ),
    )));
  }

  Widget _dock(BuildContext overlayContext) {
    final t = _text;
    final geometry = _geometry();
    if (geometry == null) return const SizedBox.shrink();
    final row = _layout(geometry.band, geometry.area);
    final bottom = _row(geometry.band);
    final markerStage = (appBand.from + appBand.to) / 2;
    final hot = _slotAt(_hot);
    return MouseRegion(onHover: (event) => _hover(event.position), onExit: (_) => _close(), child: Stack(
      children: [
        // Sliding grows the icons, a tap on one opens it, a tap anywhere else closes the dock
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onPanDown: (details) => _track(details.globalPosition),
            onPanStart: (details) => _track(details.globalPosition),
            onPanUpdate: (details) => _track(details.globalPosition),
            onPanEnd: (_) => _release(),
            onPanCancel: _cancel,
            onTapUp: (details) {
              final overlay = _overlay;
              if (overlay == null) return _close();
              final index = _hit(overlay.globalToLocal(details.globalPosition), geometry.band, row);
              final app = _slotAt(index)?.app;
              if (app != null) {
                _launch(app);
              } else if (index < 0) {
                _close();
              }
            },
          ),
        ),
        for (var i = 0; i < _slots.length; i++)
          Positioned(
            left: row[i].left,
            top: bottom - row[i].size,
            width: row[i].size,
            height: row[i].size,
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _pop,
                // Pops out of the band, the places nearest to the marker first
                builder: (context, child) {
                  final delay = (_slots[i].stage - markerStage).abs() * 0.05;
                  final local = ((_pop.value - delay) / (1 - 0.3)).clamp(0.0, 1.0);
                  final eased = Curves.easeOutBack.transform(local);
                  return Opacity(
                    opacity: math.min(1, local * 2),
                    child: Transform.translate(
                      offset: Offset(0, (1 - eased) * 14),
                      child: Transform.scale(scale: 0.4 + 0.6 * eased, alignment: Alignment.bottomCenter, child: child),
                    ),
                  );
                },
                child: _Tile(slot: _slots[i], current: _slots[i].app != null && _isCurrent(_slots[i].app!)),
              ),
            ),
          ),
        // Screen readers get the apps as links, the free spots stay silent
        for (var i = 0; i < _slots.length; i++)
          if (_slots[i].app case final app?)
            Positioned(
              left: row[i].left,
              top: bottom - row[i].size,
              width: row[i].size,
              height: row[i].size,
              child: Semantics(
                link: true,
                linkUrl: app.url,
                label: [app.name, if (app.desktop) t.desktopApp, if (_isCurrent(app)) t.youAreHere].join(', '),
                onTap: () => _launch(app),
                child: const SizedBox.expand(),
              ),
            ),
        // The label stays on screen, near the edges its tip moves off centre
        if (hot != null)
          Positioned(
            left: 8,
            right: 8,
            top: bottom - row[_hot].size - 8 - 80,
            height: 80,
            child: IgnorePointer(
              child: CustomSingleChildLayout(
                delegate: _LabelLayout(row[_hot].left + row[_hot].size / 2 - 8),
                child: _Label(
                  name: hot.app?.name ?? t.freeSpot,
                  note: switch (hot.app) {
                    final app? when _isCurrent(app) => t.youAreHere,
                    final app? when app.desktop => t.desktopApp,
                    _ => null,
                  },
                ),
              ),
            ),
          ),
      ],
    ));
  }
}

// The band is centred in the hit area beside the wordmark.
const _bandTop = 12.0;

class _BandLine extends StatelessWidget {
  final bool open;
  const _BandLine({required this.open});

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).brightness == Brightness.dark
        ? Colors.black.withValues(alpha: open ? .25 : .55) : Colors.white.withValues(alpha: open ? .25 : .6);
    final line = open ? 5.0 : 2.0;
    final marker = open ? 9.0 : 4.0;
    final middle = _bandTop + 2;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: middle - line / 2,
          height: line,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(line / 2),
              gradient: LinearGradient(colors: [for (final c in glow) Color.alphaBlend(dim, c)]),
            ),
          ),
        ),
        Positioned(
          left: _signatureWidth * (appBand.from - 1) / 6,
          top: middle - marker / 2,
          width: math.max(6, _signatureWidth * (appBand.to - appBand.from) / 6),
          height: marker,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: bandGradient(glow),
              borderRadius: BorderRadius.circular(marker / 2),
              border: open ? Border.all(color: Colors.white, width: 1.5) : null,
              boxShadow: open
                  ? [BoxShadow(color: bandColor((appBand.from + appBand.to) / 2, glow), blurRadius: 10)]
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  final DockSlot slot;
  final bool current;
  const _Tile({required this.slot, required this.current});

  @override
  Widget build(BuildContext context) {
    final app = slot.app;
    if (app == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(_base * _free * 0.225),
          border: Border.all(color: bandColor(slot.stage.toDouble(), glow), width: 1.5),
        ),
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.all(Radius.circular(9)),
              boxShadow: [BoxShadow(color: Color(0x47000000), blurRadius: 6, offset: Offset(0, 3))],
            ),
            child: app.icon == null
                ? const DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xFF121117),
                      borderRadius: BorderRadius.all(Radius.circular(9)),
                    ),
                  )
                : SvgPicture.string(app.icon!, errorBuilder: (_, _, _) => const Icon(Icons.apps, size: 24)),
          ),
        ),
        // Like a running app in the Dock
        if (current)
          Positioned(
            left: 0,
            right: 0,
            bottom: -9,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.onSurface, shape: BoxShape.circle),
                child: SizedBox(width: 4, height: 4),
              ),
            ),
          ),
      ],
    );
  }
}

// Centres the label on the tile, held inside the screen near the edges
class _LabelLayout extends SingleChildLayoutDelegate {
  final double center;
  const _LabelLayout(this.center);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    (center - childSize.width / 2).clamp(0.0, math.max(0.0, size.width - childSize.width)),
    size.height - childSize.height,
  );

  @override
  bool shouldRelayout(_LabelLayout old) => old.center != center;
}

class _Label extends StatelessWidget {
  final String name;
  final String? note;
  const _Label({required this.name, this.note});

  static const _fill = Color(0xDB242428);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: const BoxDecoration(
            color: _fill,
            borderRadius: BorderRadius.all(Radius.circular(6)),
            boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4))],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            child: Text.rich(
              TextSpan(
                text: name,
                children: [
                  if (note != null)
                    TextSpan(
                      text: '  $note',
                      style: const TextStyle(color: Color(0xFFB9B9C2), fontSize: 11),
                    ),
                ],
              ),
              style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.35),
            ),
          ),
        ),
        CustomPaint(size: const Size(10, 5), painter: _Tip(_fill)),
      ],
    );
  }
}

class _Tip extends CustomPainter {
  final Color color;
  const _Tip(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Tip old) => old.color != color;
}
