import 'package:doener_models/doener_models.dart';

import '../client.dart';
import '../command.dart';

/// Every shop the server knows by name, as the search on the map:
/// `/places/search`, nearest first with a position.
final search = Command(
  help: [
    ('search --name <text>', 'Döner-Läden nach Namen suchen'),
    ('  [--lat <breite> --lon <länge>]', 'die nächsten zuerst'),
  ],
  options: (parser) => parser
    ..addOption('name')
    ..addOption('lat')
    ..addOption('lon'),
  run: (ctx) async {
    requireLogin(ctx);
    final name = ctx.args.option('name') ?? (throw const Failure('--name <text> fehlt.', Exit.usage));
    final lat = numberOption(ctx, 'lat', required: ctx.args.option('lon') != null);
    final lon = numberOption(ctx, 'lon', required: lat != null);
    final places = parseList(
      await ctx.api.get('/places/search', {'q': name, if (lat != null) 'lat': '$lat', if (lon != null) 'lon': '$lon'}),
      PlaceDto.fromJson,
    );
    return (
      data: {'places': [for (final place in places) place.toJson()]},
      text: places.isEmpty
          ? 'Kein Laden mit diesem Namen bekannt.'
          : [for (final p in places) [p.name, ?p.address, ?p.city].join(', ')].join('\n'),
    );
  },
);
