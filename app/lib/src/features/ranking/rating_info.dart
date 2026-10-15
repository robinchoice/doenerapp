import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';

import '../../ui/widgets.dart';
import '../place/check_in_sheet.dart';

/// Who rates, what "vor Ort" and "Stammgast" check, and how the ranking
/// sorts — the law asks whether and how reviews are verified (§ 5b UWG).
Future<void> showRatingInfo(BuildContext context) => showAppSheet(context, (_) => const _RatingInfo());

class _RatingInfo extends StatelessWidget {
  const _RatingInfo();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget section(String title, String text) => Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(text),
            ],
          ),
        );
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        Text('So funktionieren Bewertungen', style: theme.textTheme.titleLarge),
        section(
          'Wer bewertet',
          'Alle mit einem Konto in der Döner App. Pro Laden zählt eine Bewertung pro Person, eine neue ersetzt die alte. '
              'Bewertungen werden nicht bezahlt.',
        ),
        section(
          'vor Ort und Stammgast',
          '„vor Ort“ heißt: Die Person hat in der App bei diesem Laden eingecheckt. Die App lässt das nur zu, wenn das Gerät '
              'meldet, höchstens ${checkInRadius.round()} m entfernt zu sein. „Stammgast“ heißt: eingecheckt an mindestens '
              '$regularVisits verschiedenen Tagen. Mehr prüfen wir nicht: Den Standort kontrolliert der Server nicht nach, und ob '
              'jemand dort wirklich gegessen hat, wissen wir nicht. Bewertungen ohne Häkchen zählen genauso.',
        ),
        section(
          'Noten',
          'Bewertet wird von 1 bis 5 in halben Schritten. Die Döner-Note ist der Schnitt aus Soße, Fleisch und Brot. '
              'Bei Vegetarisch und Vegan zählen eigene Noten, etwa für Falafel oder veganen Döner.',
        ),
        section(
          'Ranking',
          'Verglichen werden die Läden einer Stadt. Damit eine einzelne 5 nicht viele gute Bewertungen überholt, startet '
              'jeder Laden mit $rankingPriorWeight gedachten Bewertungen in Höhe des Stadtschnitts. Angezeigt werden der echte '
              'Schnitt und die Anzahl. Läden können sich keinen Platz kaufen.',
        ),
        section(
          'Gefälschte Bewertung entdeckt?',
          'Schick uns eine Nachricht über „Feedback geben“ in den Einstellungen.',
        ),
      ],
    );
  }
}
