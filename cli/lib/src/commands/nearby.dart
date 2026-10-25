import 'package:doener_models/doener_models.dart';

import '../client.dart';
import '../command.dart';

/// The best shops around a point, as on Start in the app: `/places/top`,
/// weighted rating first, unrated ones by distance after them.
final nearby = Command(
  help: [
    ('nearby --lat <breite> --lon <länge>', 'Die besten Döner-Läden in der Nähe'),
    ('  [--radius <meter>]', 'Umkreis, sonst 10000'),
    ('  [--by overall|vegetarian|vegan]', 'Wertung, sonst overall'),
    ('  [--limit <1–50>]', 'Anzahl, sonst 10'),
  ],
  options: (parser) => parser
    ..addOption('lat')
    ..addOption('lon')
    ..addOption('radius')
    ..addOption('by', allowed: ['overall', 'vegetarian', 'vegan'], defaultsTo: 'overall')
    ..addOption('limit'),
  run: (ctx) async {
    final lat = numberOption(ctx, 'lat', required: true);
    final lon = numberOption(ctx, 'lon', required: true);
    final by = ctx.args.option('by')!;
    final json = await ctx.api.get('/places/top', {
      'lat': '$lat',
      'lon': '$lon',
      'by': by,
      'radius': ?ctx.args.option('radius'),
      'limit': ?ctx.args.option('limit'),
    });
    final places = parseList(json, PlaceDto.fromJson);

    final diet = RankBy.parse(by)!.diet!;
    String line(int i, PlaceDto place) {
      final (:average, :count) = place.score(diet);
      final where = place.city == null ? '' : ', ${place.city}';
      final score = average == null ? 'noch nicht bewertet' : '${decimal(average)} (${reviewCount(count)})';
      return '${'${i + 1}.'.padLeft(3)} ${place.name}$where – $score';
    }

    return (
      data: {'places': [for (final place in places) place.toJson()]},
      text: places.isEmpty
          ? 'Hier gibt es noch keine Läden.'
          : ['${diet.scoreLabel}:', for (final (i, place) in places.indexed) line(i, place)].join('\n'),
    );
  },
);
