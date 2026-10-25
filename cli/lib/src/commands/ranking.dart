import 'package:doener_models/doener_models.dart';

import '../client.dart';
import '../command.dart';

String _line(int i, RankingEntryDto entry) => [
  '${'${i + 1}.'.padLeft(3)} ${entry.place.name} – ${decimal(entry.average)} (${reviewCount(entry.count)})',
  if (entry.price case final price?) euros(price),
  if (entry.friends.isNotEmpty)
    'Freunde: ${[for (final friend in entry.friends) '${friend.user.displayName} ${decimal(friend.rating)}'].join(', ')}',
].join(' · ');

/// The city ranking as on the ranking tab: the city around the position or
/// [city], by a diet's score or a single item.
final ranking = Command(
  help: [
    ('ranking --lat <breite> --lon <länge>', 'Die Bestenliste der Stadt'),
    ('  [--city <stadt>]', 'Eine andere Stadt als die am Standort'),
    ('  [--by overall|vegetarian|vegan|<punkt>]', 'Wonach, sonst overall, Punkte wie bei review'),
    ('  [--max-price <euro>]', 'Nur Läden, deren Döner meist höchstens so viel kostet'),
  ],
  options: (parser) => parser
    ..addOption('lat')
    ..addOption('lon')
    ..addOption('city')
    ..addOption('by', allowed: ['overall', 'vegetarian', 'vegan', for (final item in RatingItem.values) item.name], defaultsTo: 'overall')
    ..addOption('max-price'),
  run: (ctx) async {
    requireLogin(ctx);
    final ranking = parse(
      await ctx.api.get('/ranking', {
        'lat': '${numberOption(ctx, 'lat', required: true)}',
        'lon': '${numberOption(ctx, 'lon', required: true)}',
        'by': ctx.args.option('by')!,
        'city': ?ctx.args.option('city'),
        'maxPrice': ?centsOption(ctx, 'max-price')?.toString(),
      }),
      RankingDto.fromJson,
    );
    return (
      data: ranking.toJson(),
      text: switch (ranking.city) {
        null => 'Hier gibt es noch keine bewerteten Läden.',
        final city when ranking.entries.isEmpty => '$city, ${ranking.by.label}: noch keine Läden.',
        final city => ['$city, ${ranking.by.label}:', for (final (i, entry) in ranking.entries.indexed) _line(i, entry)].join('\n'),
      },
    );
  },
);
