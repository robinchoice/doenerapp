import 'package:doener_models/doener_models.dart';
import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';

import 'deps.dart';
import 'google_places.dart';
import 'places.dart' show storeFoundPlaces;

/// An area whose shops the map shows before anyone has looked there.
class PrefetchArea {
  final String name;
  final double south;
  final double west;
  final double north;
  final double east;
  const PrefetchArea(this.name, this.south, this.west, this.north, this.east);

  /// About 18 × 18 km around the centre, [scale] times that for big cities.
  PrefetchArea.city(this.name, double lat, double lon, [double scale = 1])
      : south = lat - 0.08 * scale,
        north = lat + 0.08 * scale,
        west = lon - 0.12 * scale,
        east = lon + 0.12 * scale;
}

/// Searched in this order: the cities Robin named, Saarland and
/// Baden-Württemberg as a whole, then the other cities above 100,000.
final prefetchAreas = [
  PrefetchArea.city('Freiburg', 47.99, 7.85),
  PrefetchArea.city('Mannheim', 49.49, 8.47),
  PrefetchArea.city('Heidelberg', 49.40, 8.69),
  PrefetchArea.city('Karlsruhe', 49.01, 8.40),
  PrefetchArea.city('Ulm', 48.40, 9.99),
  PrefetchArea.city('Saarbrücken', 49.24, 6.99),
  PrefetchArea.city('Trier', 49.75, 6.64),
  PrefetchArea.city('Berlin', 52.52, 13.40, 2),
  PrefetchArea.city('Hamburg', 53.55, 10.00, 1.8),
  PrefetchArea.city('München', 48.14, 11.58, 1.5),
  PrefetchArea.city('Düsseldorf', 51.23, 6.78),
  const PrefetchArea('Saarland', 49.11, 6.35, 49.64, 7.41),
  const PrefetchArea('Baden-Württemberg', 47.53, 7.50, 49.80, 10.50),
  PrefetchArea.city('Köln', 50.94, 6.96, 1.5),
  PrefetchArea.city('Frankfurt am Main', 50.11, 8.68, 1.2),
  PrefetchArea.city('Essen', 51.46, 7.01),
  PrefetchArea.city('Dortmund', 51.51, 7.47),
  PrefetchArea.city('Duisburg', 51.43, 6.76),
  PrefetchArea.city('Bochum', 51.48, 7.22),
  PrefetchArea.city('Gelsenkirchen', 51.52, 7.10),
  PrefetchArea.city('Wuppertal', 51.26, 7.15),
  PrefetchArea.city('Leipzig', 51.34, 12.37),
  PrefetchArea.city('Dresden', 51.05, 13.74),
  PrefetchArea.city('Hannover', 52.37, 9.73),
  PrefetchArea.city('Nürnberg', 49.45, 11.08),
  PrefetchArea.city('Bremen', 53.08, 8.80),
  PrefetchArea.city('Bielefeld', 52.02, 8.53),
  PrefetchArea.city('Bonn', 50.73, 7.10),
  PrefetchArea.city('Münster', 51.96, 7.63),
  PrefetchArea.city('Augsburg', 48.37, 10.90),
  PrefetchArea.city('Wiesbaden', 50.08, 8.24),
  PrefetchArea.city('Mainz', 50.00, 8.27),
  PrefetchArea.city('Mönchengladbach', 51.19, 6.44),
  PrefetchArea.city('Krefeld', 51.33, 6.56),
  PrefetchArea.city('Aachen', 50.78, 6.08),
  PrefetchArea.city('Braunschweig', 52.27, 10.52),
  PrefetchArea.city('Kiel', 54.32, 10.13),
  PrefetchArea.city('Chemnitz', 50.83, 12.92),
  PrefetchArea.city('Halle', 51.48, 11.97),
  PrefetchArea.city('Magdeburg', 52.13, 11.63),
  PrefetchArea.city('Lübeck', 53.87, 10.69),
  PrefetchArea.city('Erfurt', 50.98, 11.03),
  PrefetchArea.city('Rostock', 54.09, 12.14),
  PrefetchArea.city('Kassel', 51.31, 9.48),
  PrefetchArea.city('Hagen', 51.36, 7.47),
  PrefetchArea.city('Hamm', 51.68, 7.82),
  PrefetchArea.city('Potsdam', 52.40, 13.07),
  PrefetchArea.city('Oldenburg', 53.14, 8.21),
  PrefetchArea.city('Osnabrück', 52.28, 8.05),
  PrefetchArea.city('Darmstadt', 49.87, 8.65),
  PrefetchArea.city('Regensburg', 49.01, 12.10),
  PrefetchArea.city('Paderborn', 51.72, 8.75),
  PrefetchArea.city('Ingolstadt', 48.77, 11.43),
  PrefetchArea.city('Würzburg', 49.79, 9.95),
  PrefetchArea.city('Wolfsburg', 52.42, 10.79),
  PrefetchArea.city('Göttingen', 51.54, 9.93),
  PrefetchArea.city('Recklinghausen', 51.61, 7.20),
  PrefetchArea.city('Bremerhaven', 53.55, 8.58),
  PrefetchArea.city('Koblenz', 50.36, 7.59),
  PrefetchArea.city('Jena', 50.93, 11.59),
  PrefetchArea.city('Erlangen', 49.59, 11.00),
  PrefetchArea.city('Siegen', 50.87, 8.02),
  PrefetchArea.city('Hildesheim', 52.15, 9.95),
  PrefetchArea.city('Salzgitter', 52.15, 10.33),
  PrefetchArea.city('Cottbus', 51.76, 14.33),
  PrefetchArea.city('Kaiserslautern', 49.44, 7.77),
  PrefetchArea.city('Gütersloh', 51.91, 8.38),
  PrefetchArea.city('Schwerin', 53.63, 11.41),
  PrefetchArea.city('Gera', 50.88, 12.08),
  PrefetchArea.city('Zwickau', 50.72, 12.49),
  PrefetchArea.city('Düren', 50.80, 6.48),
  PrefetchArea.city('Flensburg', 54.78, 9.44),
  PrefetchArea.city('Hanau', 50.13, 8.92),
];

/// One run searches with at most this many requests. Together with the
/// users' tile searches it stays within the project's daily SearchText quota
/// (infra.md), which keeps the searches inside Google's free Pro requests.
const prefetchRequestsPerRun = 110;

/// Areas are searched in blocks of 8 × 8 tiles (about 27 × 17 km). Where a
/// block has more shops than one search returns, its quarters are searched.
const _rootSize = 8;

/// The blocks covering [areas], in their order, each once.
List<TileBlock> prefetchBlocks(List<PrefetchArea> areas) {
  final blocks = <TileBlock>{};
  int start(double deg) => (deg / tileSizeDeg / _rootSize).floor() * _rootSize;
  for (final a in areas) {
    for (var y = start(a.south); y * tileSizeDeg < a.north; y += _rootSize) {
      for (var x = start(a.west); x * tileSizeDeg < a.east; x += _rootSize) {
        blocks.add(TileBlock(x, y, _rootSize));
      }
    }
  }
  return blocks.toList();
}

/// Searches the [prefetchAreas] block by block. A block counts as searched
/// for [tileTtl] like a tile a user's map searched, so each run goes on where
/// the last one stopped, and after 25 days it starts over.
Future<void> prefetchPlaces(Deps deps, {List<PrefetchArea>? areas, int budget = prefetchRequestsPerRun}) async {
  final apiKey = deps.config.googlePlacesApiKey;
  if (apiKey == null) return;
  var left = budget;

  Future<void> search(TileBlock block) async {
    if (left < maxPagesPerSearch || !await _due(deps, block)) return;
    Future<void> found(SearchResult result) async {
      left -= result.requests;
      await storeFoundPlaces(deps, result.places);
    }

    final result = await searchArea(deps.httpClient, apiKey, block.rect);
    await found(result);
    if (result.full && block.size > 1) {
      for (final quarter in block.quarters) {
        await search(quarter);
      }
      return;
    }
    // A full single tile is split further. Without the budget for that it
    // stays due, and the next run searches it again.
    if (result.full &&
        !await searchQuarters(deps.httpClient, apiKey, block.rect,
            splits: maxTileSplits, maySplit: () async => left >= 4 * maxPagesPerSearch, found: found)) {
      return;
    }
    await _markSearched(deps, block);
  }

  try {
    for (final block in prefetchBlocks(areas ?? prefetchAreas)) {
      if (left < maxPagesPerSearch) break;
      await search(block);
    }
  } on http.ClientException catch (e) {
    // Mostly the daily quota; the next run goes on.
    print('Place prefetch stopped: $e');
  }
  print('Place prefetch: ${budget - left} requests');
}

Future<bool> _due(Deps deps, TileBlock block) async {
  final keys = [for (final t in block.tiles) t.key];
  final fresh = await queryOne(
    deps.db,
    'SELECT count(*)::int AS n FROM search_tiles WHERE tile_key = ANY(@keys:_text) '
    'AND searched_at > now() - make_interval(days => @ttl:int4)',
    {'keys': keys, 'ttl': tileTtl.inDays},
  );
  return (fresh!['n'] as int) < keys.length;
}

Future<void> _markSearched(Deps deps, TileBlock block) => deps.db.execute(
      Sql.named(
        'INSERT INTO search_tiles (tile_key, searched_at) SELECT unnest(@keys:_text), now() '
        'ON CONFLICT (tile_key) DO UPDATE SET searched_at = now()',
      ),
      parameters: {'keys': [for (final t in block.tiles) t.key]},
    );
