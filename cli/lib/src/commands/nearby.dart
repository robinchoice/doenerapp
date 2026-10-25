import 'package:doener_models/doener_models.dart';

import '../client.dart';
import '../command.dart';

double _coordinate(Context ctx, String name) {
  final value = double.tryParse(ctx.args.option(name) ?? '');
  if (value == null) throw Failure('--$name <zahl> fehlt oder ist keine Zahl.', Exit.usage);
  return value;
}

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
    final lat = _coordinate(ctx, 'lat');
    final lon = _coordinate(ctx, 'lon');
    final by = ctx.args.option('by')!;
    final json = await ctx.api.get('/places/top', {
      'lat': '$lat',
      'lon': '$lon',
      'by': by,
      'radius': ?ctx.args.option('radius'),
      'limit': ?ctx.args.option('limit'),
    });
    if (json is! List) throw const Failure('Unerwartete Antwort der API.', Exit.error);
    final places = [for (final place in json) parse(place, PlaceDto.fromJson)];

    final diet = RankBy.parse(by)!.diet!;
    String line(int i, PlaceDto place) {
      final (:average, :count) = place.score(diet);
      final where = place.city == null ? '' : ', ${place.city}';
      final score = average == null
          ? 'noch nicht bewertet'
          : '${average.toStringAsFixed(1).replaceAll('.', ',')} (${count == 1 ? '1 Bewertung' : '$count Bewertungen'})';
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
