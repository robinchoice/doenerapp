import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_data.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';

enum _Answer { yes, no, unknown }

/// What the card at the top rates: the Döner, or the food without meat.
List<RatingItem> _mainItems(Diet diet) => switch (diet) {
      Diet.all => RatingItem.doenerItems,
      Diet.vegetarian => const [RatingItem.falafel, RatingItem.halloumi, RatingItem.sauce, RatingItem.brot],
      Diet.vegan => const [RatingItem.veganDoener, RatingItem.falafel, RatingItem.veganSauce, RatingItem.hummus, RatingItem.brot],
    };

String _mainTitle(Diet diet) => switch (diet) { Diet.all => '🥙 Döner', Diet.vegetarian => '🧆 Ohne Fleisch', Diet.vegan => '🌱 Vegan' };

/// Pops `true` when a review was saved. Experts start from what others said
/// "mit allem" means here ([summary]).
class ReviewSheet extends StatefulWidget {
  final PlaceDto place;
  final PlaceSummaryDto? summary;
  const ReviewSheet({super.key, required this.place, this.summary});

  @override
  State<ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<ReviewSheet> {
  late final ReviewDto? _existing = context.read<AppData>().reviews[widget.place.placeId]?.dto;
  late final Diet _diet = context.read<Session>().diet;
  late final bool _expert = context.read<Session>().expertMode;
  late final _text = TextEditingController(text: _existing?.text);
  late final _ratings = {...?_existing?.ratings};
  late final _extras = {for (final item in RatingItem.extraItems) if (_ratings.containsKey(item)) item};
  late _Answer? _vegan = _answer(_existing?.veganOptions);
  late _Answer? _ayran = _answer(_existing?.ayranHomemade);
  late final _ingredients = <Ingredient>{...?(_existing?.ingredients ?? widget.summary?.ingredients)};
  late Meat? _meat = _existing?.meat ?? widget.summary?.meat;
  late Skewer? _skewer = _existing?.skewer ?? widget.summary?.skewer;
  late Bread? _bread = _existing?.bread ?? widget.summary?.bread;

  /// Prefilled from the others, the expert part only counts once it's touched.
  late bool _expertTouched = _existing?.ingredients != null;

  static _Answer? _answer(bool? value) => value == null ? null : (value ? _Answer.yes : _Answer.no);
  static bool? _bool(_Answer? answer) => switch (answer) { _Answer.yes => true, _Answer.no => false, _ => null };

  bool get _canSave =>
      _ratings.isNotEmpty ||
      _bool(_vegan) != null ||
      _bool(_ayran) != null ||
      _expertTouched ||
      Validation.clean(_text.text) != null;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _rate(RatingItem item, int value) => setState(() {
        if (value == 0) {
          _ratings.remove(item);
          return;
        }
        _ratings[item] = value;
        // Rating vegan food or ayran answers the question.
        if (RatingItem.veganItems.contains(item)) _vegan = _Answer.yes;
        if (item == RatingItem.ayran) _ayran = _Answer.yes;
      });

  void _toggleExtra(RatingItem item) => setState(() {
        if (_extras.remove(item)) {
          _ratings.remove(item);
        } else {
          _extras.add(item);
        }
      });

  void _answerVegan(_Answer? answer) => setState(() {
        _vegan = answer;
        if (answer != _Answer.yes) RatingItem.veganItems.forEach(_ratings.remove);
      });

  void _answerAyran(_Answer? answer) => setState(() {
        _ayran = answer;
        if (answer != _Answer.yes) _ratings.remove(RatingItem.ayran);
      });

  void _expertChange(VoidCallback change) => setState(() {
        change();
        _expertTouched = true;
      });

  Future<void> _save() async {
    await context.read<AppData>().saveReview(
          widget.place,
          UpsertReviewRequest(
            ratings: Map.of(_ratings),
            veganOptions: _bool(_vegan),
            ayranHomemade: _bool(_ayran),
            // Without expert mode, earlier answers stay as they were.
            ingredients: _expertTouched ? (_ingredients.toList()..sort((a, b) => a.index.compareTo(b.index))) : _existing?.ingredients,
            meat: _expertTouched ? _meat : _existing?.meat,
            skewer: _expertTouched ? _skewer : _existing?.skewer,
            bread: _expertTouched ? _bread : _existing?.bread,
            text: Validation.clean(_text.text),
          ),
        );
    if (mounted) Navigator.of(context).pop(true);
  }

  Widget _row(RatingItem item) {
    final value = _ratings[item] ?? 0;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.label),
                if (item.hint != null) Text(item.hint!, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
          ),
          DoenerRating(value: value, size: 28, onChanged: (v) => _rate(item, v)),
          // Fixed slot so the row height doesn't jump when the clear button appears.
          SizedBox.square(
            dimension: 40,
            child: value > 0 ? IconButton(icon: const Icon(Icons.cancel, size: 18), onPressed: () => _rate(item, 0)) : null,
          ),
        ],
      ),
    );
  }

  Widget _question(String title, _Answer? value, ValueChanged<_Answer?> onChanged, List<RatingItem> items) {
    final theme = Theme.of(context);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final (answer, label) in const [(_Answer.yes, 'Ja'), (_Answer.no, 'Nein'), (_Answer.unknown, 'Weiß nicht')])
                ChoiceChip(label: Text(label), selected: value == answer, onSelected: (on) => onChanged(on ? answer : null)),
            ],
          ),
          if (value == _Answer.yes) ...[
            const SizedBox(height: 4),
            for (final item in items) _row(item),
            Text('Nur bewerten, was du probiert hast. „Ja“ allein hilft auch.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
          ],
        ],
      ),
    );
  }

  Widget _expertCard() {
    final theme = Theme.of(context);
    Widget label(String text) => Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 6),
          child: Text(text, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
        );
    Widget pick<T>(List<T> values, T? selected, String Function(T) labelOf, void Function(T?) onPicked) => Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final v in values)
              ChoiceChip(label: Text(labelOf(v)), selected: selected == v, onSelected: (on) => _expertChange(() => onPicked(on ? v : null))),
          ],
        );
    final hint = _existing?.ingredients != null
        ? 'Deine Angaben vom letzten Mal.'
        : (widget.summary?.experts ?? 0) > 0
            ? 'Vorausgefüllt mit dem, was andere angekreuzt haben. Tipp an, was fehlte oder dazukam.'
            : 'Tipp an, was mit drin war.';
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('🔎 Mit allem heißt hier …', style: theme.textTheme.titleSmall),
          Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
          for (final group in IngredientGroup.values) ...[
            label(group == IngredientGroup.special ? '${group.label} ✨' : group.label),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final i in Ingredient.values.where((i) => i.group == group))
                  FilterChip(
                    label: Text(i.label),
                    selected: _ingredients.contains(i),
                    onSelected: (on) => _expertChange(() => on ? _ingredients.add(i) : _ingredients.remove(i)),
                  ),
              ],
            ),
          ],
          if (_diet == Diet.all) ...[
            label('Fleisch'),
            pick(Meat.values, _meat, (m) => m.label, (m) => _meat = m),
            label('Spieß'),
            pick(Skewer.values, _skewer, (s) => s.label, (s) => _skewer = s),
          ],
          label('Brot'),
          pick(Bread.values, _bread, (b) => b.label, (b) => _bread = b),
        ],
      ),
    );
  }

  static const _labels = ['', 'Schlecht', 'Naja', 'Okay', 'Gut', 'Ausgezeichnet'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final main = _mainItems(_diet);
    final extras = [for (final item in RatingItem.extraItems) if (_diet.allows(item.diet) && !main.contains(item)) item];
    // An older review may only have an overall rating; it shows until sauce, meat or bread get one.
    final keepsOld = _diet == Diet.all &&
        !RatingItem.doenerItems.any((i) => _ratings.containsKey(i) || (_existing?.ratings.containsKey(i) ?? false));
    final score = _diet.score(_ratings)?.round() ?? (keepsOld ? _existing?.rating : null) ?? 0;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        Text(_existing == null ? 'Bewerten' : 'Bewertung bearbeiten', style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
        Text(widget.place.name, textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.outline)),
        const SizedBox(height: 16),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_mainTitle(_diet), style: theme.textTheme.titleSmall),
              for (final item in main) _row(item),
              const Divider(height: 20),
              Row(
                children: [
                  Text('Gesamt', style: theme.textTheme.titleSmall),
                  const SizedBox(width: 12),
                  DoenerRating(value: score, size: 22),
                  const SizedBox(width: 10),
                  if (score > 0)
                    Flexible(
                      child: Text(
                        _labels[score],
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: doenerOrange, fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (_diet == Diet.vegan)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => _answerVegan(_vegan == _Answer.no ? null : _Answer.no),
              child: Text(_vegan == _Answer.no ? '✓ Hier gibt’s nichts Veganes' : 'Hier gibt’s nichts Veganes'),
            ),
          ),
        if (extras.isNotEmpty) ...[
          const SizedBox(height: 12),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Was gab’s noch?', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final item in extras)
                      FilterChip(
                        avatar: Text(item.emoji),
                        label: Text(item.label),
                        selected: _extras.contains(item),
                        onSelected: (_) => _toggleExtra(item),
                      ),
                  ],
                ),
                for (final item in extras)
                  if (_extras.contains(item)) _row(item),
              ],
            ),
          ),
        ],
        if (_diet != Diet.vegan) ...[
          const SizedBox(height: 12),
          _question('🌱 Vegane Optionen?', _vegan, _answerVegan, RatingItem.veganItems),
          const SizedBox(height: 12),
          _question('🥛 Selbstgemachter Ayran?', _ayran, _answerAyran, const [RatingItem.ayran]),
        ],
        if (_expert) ...[const SizedBox(height: 12), _expertCard()],
        const SizedBox(height: 16),
        TextField(
          controller: _text,
          minLines: 3,
          maxLines: 6,
          maxLength: Validation.reviewTextMax,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(hintText: 'Was war gut, was nicht? (optional)'),
        ),
        const SizedBox(height: 8),
        FilledButton(onPressed: _canSave ? _save : null, child: const Text('Speichern')),
      ],
    );
  }
}
