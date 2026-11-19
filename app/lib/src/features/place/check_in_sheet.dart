import 'dart:math' as math;

import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_data.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';

/// Check-ins only count on site.
const checkInRadius = 150.0;

class CheckInSheet extends StatefulWidget {
  /// Shops within [checkInRadius], nearest first.
  final List<PlaceDto> places;
  const CheckInSheet({super.key, required this.places});

  @override
  State<CheckInSheet> createState() => _CheckInSheetState();
}

class _CheckInSheetState extends State<CheckInSheet> {
  late PlaceDto _place = widget.places.first;
  late final _foods = FoodItem.forDiet(context.read<Session>().diet);
  int _selected = 0;
  bool _done = false;

  Future<void> _checkIn() async {
    setState(() => _done = true);
    await context.read<AppData>().checkIn(_place, foodType: _foods[_selected].id);
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    // Closed by hand meanwhile: popping now would close the app's screen behind it.
    if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Text('Einchecken', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
            if (widget.places.length == 1)
              Text(_place.name, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.outline))
            else
              // Several shops next to each other: nearest first, the user picks.
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final p in widget.places)
                    ChoiceChip(
                      label: Text(p.name),
                      selected: p == _place,
                      onSelected: _done ? null : (_) => setState(() => _place = p),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            IgnorePointer(ignoring: _done, child: RotaryPicker(items: _foods, selected: _selected, onChanged: (i) => setState(() => _selected = i))),
            Text(Localizations.localeOf(context).languageCode == 'en'
              ? 'Turn the ring. Your choice snaps to the top.' : 'Drehe den Ring. Die Auswahl rastet oben ein.',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            Center(
              child: FilledButton.icon(onPressed: _done ? null : _checkIn, icon: const Icon(Icons.check),
                label: Text('${_foods[_selected].label} · ${Localizations.localeOf(context).languageCode == 'en' ? 'Check in now' : 'Jetzt einchecken'}')),
            ),
          ],
        ),
        if (_done) Positioned.fill(child: IgnorePointer(child: Confetti(emoji: _foods[_selected].emoji))),
      ],
    );
  }
}

/// A fixed selection point at the top; the ring follows the finger's angle.
class RotaryPicker extends StatefulWidget {
  final List<FoodItem> items;
  final int selected;
  final ValueChanged<int> onChanged;
  const RotaryPicker({super.key, required this.items, required this.selected, required this.onChanged});

  @override
  State<RotaryPicker> createState() => _RotaryPickerState();
}

class _RotaryPickerState extends State<RotaryPicker> {
  double _rotation = 0;
  double _lastAngle = 0;
  int _base = 0;
  bool _dragging = false;
  double get _step => 360 / widget.items.length;
  int _wrap(int index) => (index % widget.items.length + widget.items.length) % widget.items.length;
  double _angle(Offset point, Offset center) => math.atan2(point.dy - center.dy, point.dx - center.dx) * 180 / math.pi;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final radius = math.min(math.max(100.0, 10.0 * widget.items.length), (constraints.maxWidth - 60) / 2);
    final height = radius * 2 + 100;
    final center = Offset(constraints.maxWidth / 2, height / 2);
    final theme = Theme.of(context);
    final en = Localizations.localeOf(context).languageCode == 'en';
    void start(DragStartDetails d) => setState(() {
      _base = widget.selected; _rotation = 0; _dragging = true; _lastAngle = _angle(d.localPosition, center);
    });
    void update(DragUpdateDetails d) {
      final angle = _angle(d.localPosition, center);
      setState(() { _rotation += (angle - _lastAngle + 540) % 360 - 180; _lastAngle = angle; });
      widget.onChanged(_wrap(_base - (_rotation / _step).round()));
    }
    return Focus(
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowRight || event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          widget.onChanged(_wrap(widget.selected + (event.logicalKey == LogicalKeyboardKey.arrowRight ? 1 : -1)));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(label: en ? 'Food wheel' : 'Essensrad', value: widget.items[widget.selected].label,
        increasedValue: widget.items[_wrap(widget.selected + 1)].label,
        decreasedValue: widget.items[_wrap(widget.selected - 1)].label,
        onIncrease: () => widget.onChanged(_wrap(widget.selected + 1)),
        onDecrease: () => widget.onChanged(_wrap(widget.selected - 1)),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragStart: start,
          onVerticalDragStart: start,
          onHorizontalDragUpdate: update,
          onVerticalDragUpdate: update,
          onHorizontalDragEnd: (_) => setState(() => _dragging = false),
          onVerticalDragEnd: (_) => setState(() => _dragging = false),
          onHorizontalDragCancel: () => setState(() => _dragging = false),
          onVerticalDragCancel: () => setState(() => _dragging = false),
          child: SizedBox(height: height, child: Stack(alignment: Alignment.center, children: [
            Container(width: radius * 2, height: radius * 2,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: theme.colorScheme.surfaceContainerHighest, width: 18))),
            Positioned(top: center.dy - radius - 50, left: center.dx - 16,
              child: Icon(Icons.arrow_drop_down, size: 32, color: context.accent)),
            for (var i = 0; i < widget.items.length; i++)
              Builder(builder: (context) {
                final angle = ((i - (_dragging ? _base : widget.selected)) * _step + (_dragging ? _rotation : 0)) * math.pi / 180;
                return AnimatedPositioned(
                  duration: _dragging || MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  left: center.dx + math.sin(angle) * radius - 24,
                  top: center.dy - math.cos(angle) * radius - 24,
                  width: 48, height: 48,
                  child: Semantics(button: true, selected: widget.selected == i, label: widget.items[i].label,
                    child: InkWell(onTap: () => widget.onChanged(i), customBorder: const CircleBorder(),
                      child: Container(alignment: Alignment.center, decoration: BoxDecoration(shape: BoxShape.circle,
                        color: widget.selected == i ? theme.colorScheme.secondaryContainer : theme.colorScheme.surface),
                        child: Text(widget.items[i].emoji, style: const TextStyle(fontSize: 30))))),
                );
              }),
            IgnorePointer(child: SizedBox(width: radius * 1.2, child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(widget.items[widget.selected].emoji, style: const TextStyle(fontSize: 40)),
              Text(widget.items[widget.selected].label, textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ]))),
          ])),
        )),
    );
  });
}

/// Emoji rain after a check-in.
class Confetti extends StatefulWidget {
  final String emoji;
  const Confetti({super.key, required this.emoji});

  @override
  State<Confetti> createState() => _ConfettiState();
}

class _ConfettiState extends State<Confetti> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..forward();
  final _random = math.Random();
  late final _particles = List.generate(
    20,
    (_) => (x: _random.nextDouble(), size: 20 + _random.nextDouble() * 20, delay: _random.nextDouble() * 0.2, rotation: _random.nextDouble() - 0.5),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Stack(
            children: [
              for (final p in _particles)
                Positioned(
                  left: p.x * (constraints.maxWidth - p.size),
                  top: -50 + Curves.easeIn.transform(((_controller.value - p.delay) / (1 - p.delay)).clamp(0, 1)) * (constraints.maxHeight + 100),
                  child: Transform.rotate(angle: p.rotation, child: Text(widget.emoji, style: TextStyle(fontSize: p.size))),
                ),
            ],
          ),
        ),
      );
}
