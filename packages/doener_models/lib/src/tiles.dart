/// The server discovers places per map tile, at most [maxTilesPerRequest]
/// per map request. Bigger areas only show places that are already known.
const tileSizeDeg = 0.03;
const maxTilesPerRequest = 16;

class Tile {
  final int x;
  final int y;
  const Tile(this.x, this.y);

  String get key => '$x:$y';
  double get minLat => y * tileSizeDeg;
  double get maxLat => (y + 1) * tileSizeDeg;
  double get minLon => x * tileSizeDeg;
  double get maxLon => (x + 1) * tileSizeDeg;

  @override
  bool operator ==(Object other) => other is Tile && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(x, y);
}

List<Tile> tilesCovering({
  required double minLat,
  required double minLon,
  required double maxLat,
  required double maxLon,
}) {
  final tiles = <Tile>[];
  for (var y = (minLat / tileSizeDeg).floor(); y <= (maxLat / tileSizeDeg).floor(); y++) {
    for (var x = (minLon / tileSizeDeg).floor(); x <= (maxLon / tileSizeDeg).floor(); x++) {
      tiles.add(Tile(x, y));
    }
  }
  return tiles;
}
