import 'dart:math' as math;

import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
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
    if (mounted) Navigator.of(context).pop();
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
            RotaryPicker(items: _foods, selected: _selected, onChanged: (i) => setState(() => _selected = i)),
            Center(
              child: GradientCircle(size: 72, active: !_done, onPressed: _done ? null : _checkIn, child: const Icon(Icons.check)),
            ),
          ],
        ),
        if (_done) Positioned.fill(child: IgnorePointer(child: Confetti(emoji: _foods[_selected].emoji))),
      ],
    );
  }
}

/// Food wheel: drag sideways or tap an item to rotate it to the top.
class RotaryPicker extends StatefulWidget {
  final List<FoodItem> items;
  final int selected;
  final ValueChanged<int> onChanged;
  const RotaryPicker({super.key, required this.items, required this.selected, required this.onChanged});

  @override
  State<RotaryPicker> createState() => _RotaryPickerState();
}

class _RotaryPickerState extends State<RotaryPicker> {
  double _drag = 0;

  /// More food needs a wider wheel, so neighbours don't overlap.
  double get _radius => math.max(100, 10.0 * widget.items.length);
  double get _step => 360 / widget.items.length;

  void _settle() {
    final steps = (-_drag / _step).round();
    final count = widget.items.length;
    widget.onChanged(((widget.selected + steps) % count + count) % count);
    setState(() => _drag = 0);
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return GestureDetector(
      onHorizontalDragUpdate: (d) => setState(() => _drag += d.delta.dx * 0.5),
      onHorizontalDragEnd: (_) => _settle(),
      child: SizedBox(
        height: _radius * 2 + 90,
        child: Stack(
          alignment: Alignment.center,
          children: [
            for (var i = 0; i < items.length; i++)
              Builder(builder: (context) {
                final angle = (i - widget.selected) * _step + _drag;
                final normalized = (((angle % 360) + 540) % 360 - 180).abs() / 180; // 0 at top, 1 at bottom
                final radians = angle * math.pi / 180;
                return AnimatedSlide(
                  duration: _drag == 0 ? const Duration(milliseconds: 300) : Duration.zero,
                  curve: Curves.easeOutBack,
                  offset: Offset(math.sin(radians) * _radius / 60, -math.cos(radians) * _radius / 60),
                  child: GestureDetector(
                    onTap: () => widget.onChanged(i),
                    child: SizedBox(
                      width: 60,
                      height: 60,
                      child: Center(
                        child: Opacity(
                          opacity: 1 - normalized * 0.5,
                          child: Text(items[i].emoji, style: TextStyle(fontSize: 44 * (1.3 - normalized * 0.7))),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                items[widget.selected].label,
                key: ValueKey(widget.selected),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
