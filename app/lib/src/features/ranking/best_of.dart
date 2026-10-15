import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/session.dart';
import '../../ui/widgets.dart';

/// The public page of a best-of list (or a shop's seals) in the browser.
Future<void> openBestOfPage(BuildContext context, String path) async {
  final uri = Uri.parse(context.read<Session>().apiBase).resolve(path);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Glow on dark ground, deep on light, in the seal's colours.
LinearGradient _gradient(BuildContext context, BestOfCategory category) => bandGradient(
      Theme.of(context).brightness == Brightness.dark ? glow : deep,
      band: category == BestOfCategory.vegan ? veganBand : appBand,
    );

Widget _gradientText(BuildContext context, BestOfCategory category, Widget child) => ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => _gradient(context, category).createShader(bounds),
      child: child,
    );

String awardTitle(AwardDto a) =>
    a.category == BestOfCategory.vegan ? 'Vegan: Platz ${a.rank} in ${a.city} ${a.year}' : 'Platz ${a.rank} in ${a.city} ${a.year}';

/// The line above a shop's name: "PLATZ 1 IN FREIBURG 2026 · VEGAN PLATZ 3".
class AwardLine extends StatelessWidget {
  final List<AwardDto> awards;
  const AwardLine({super.key, required this.awards});

  @override
  Widget build(BuildContext context) {
    final style = displayStyle.copyWith(fontSize: 14, letterSpacing: 0.6);
    final first = awards.first;
    return Wrap(children: [
      _gradientText(context, first.category, Text(awardTitle(first).toUpperCase(), style: style)),
      for (final a in awards.skip(1))
        _gradientText(context, a.category, Text(' · ${a.category == BestOfCategory.vegan ? 'VEGAN ' : ''}PLATZ ${a.rank}', style: style)),
    ]);
  }
}

/// What the seal stands on, with the way to the list: "Ø 4,7 aus 38 Bewertungen 2026 · Bestenliste ›".
class AwardStats extends StatelessWidget {
  final AwardDto award;
  const AwardStats({super.key, required this.award});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => openBestOfPage(context, award.path),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: 'Ø ${formatRating(award.average)} aus ${award.count} Bewertungen ${award.year} · '),
              TextSpan(text: 'Bestenliste ${award.year} ›', style: TextStyle(color: context.accent, fontWeight: FontWeight.w600)),
            ]),
            style: TextStyle(color: Theme.of(context).colorScheme.outline, fontSize: 13),
          ),
        ),
      );
}

/// Above the ranking: the city's latest list, its first places and the way to it.
class BestOfBanner extends StatelessWidget {
  final BestOfDto bestOf;
  const BestOfBanner({super.key, required this.bestOf});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: EdgeInsets.zero,
      onTap: () => openBestOfPage(context, bestOf.path),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const BrandTile(size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Die besten Döner in ${bestOf.city} ${bestOf.year}',
                          style: displayStyle.copyWith(fontSize: 19, color: theme.colorScheme.onSurface)),
                      Text(bestOf.category == BestOfCategory.vegan ? 'Die Bestenliste · Vegan' : 'Die Bestenliste',
                          style: TextStyle(color: theme.colorScheme.outline, fontSize: 13)),
                    ]),
                  ),
                  Icon(Icons.chevron_right, color: theme.colorScheme.outline),
                ]),
                const SizedBox(height: 8),
                for (final e in bestOf.entries)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(children: [
                      SizedBox(
                        width: 20,
                        child: _gradientText(context, bestOf.category, Text('${e.rank}', style: numberStyle.copyWith(fontSize: 17))),
                      ),
                      Expanded(child: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ]),
                  ),
              ],
            ),
          ),
          Container(height: 3, decoration: BoxDecoration(gradient: _gradient(context, bestOf.category))),
        ],
      ),
    );
  }
}
