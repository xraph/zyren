import 'dart:math' as math;
import 'geodesy.dart';

/// Radian bounds. A west value above east represents a dateline crossing.
final class GeographicRectangle {
  final double west, south, east, north;
  const GeographicRectangle(this.west, this.south, this.east, this.north);
  static const maximum = GeographicRectangle(
    -math.pi,
    -math.pi / 2,
    math.pi,
    math.pi / 2,
  );
  double get width => east < west ? east + 2 * math.pi - west : east - west;
  double get height => north - south;

  /// Upstream interpolation uses raw endpoints, with Y increasing southward.
  /// It does not unwrap a dateline-crossing rectangle before interpolation.
  Geodetic at(double x, double y) =>
      Geodetic(west + (east - west) * x, north + (south - north) * y);
  factory GeographicRectangle.fromList(List<double> values, [int offset = 0]) =>
      GeographicRectangle(
        values[offset],
        values[offset + 1],
        values[offset + 2],
        values[offset + 3],
      );
  List<double> toList() => [west, south, east, north];
  GeographicRectangle copyWith({
    double? west,
    double? south,
    double? east,
    double? north,
  }) => GeographicRectangle(
    west ?? this.west,
    south ?? this.south,
    east ?? this.east,
    north ?? this.north,
  );
  @override
  bool operator ==(Object other) =>
      other is GeographicRectangle &&
      west == other.west &&
      south == other.south &&
      east == other.east &&
      north == other.north;
  @override
  int get hashCode => Object.hash(west, south, east, north);
}

/// Geographic tile coordinates use Y zero at the south edge.
final class TileCoordinate {
  final int x, y, z;
  const TileCoordinate(this.x, this.y, this.z);
  factory TileCoordinate.fromList(List<int> values, [int offset = 0]) =>
      TileCoordinate(values[offset], values[offset + 1], values[offset + 2]);
  List<int> toList() => [x, y, z];
  TileCoordinate copyWith({int? x, int? y, int? z}) =>
      TileCoordinate(x ?? this.x, y ?? this.y, z ?? this.z);

  /// Like upstream, the parent of a level-zero coordinate has level -1.
  TileCoordinate get parent =>
      TileCoordinate((x / 2).floor(), (y / 2).floor(), z - 1);

  /// Yields only descendants at [depth], in southwest, southeast, northwest,
  /// northeast depth-first order. Depth zero yields no coordinates.
  Iterable<TileCoordinate> traverseChildren(int depth) sync* {
    if (depth < 0 || depth > 30) throw RangeError.range(depth, 0, 30, 'depth');
    if (depth == 0) return;
    for (final child in [
      TileCoordinate(x * 2, y * 2, z + 1),
      TileCoordinate(x * 2 + 1, y * 2, z + 1),
      TileCoordinate(x * 2, y * 2 + 1, z + 1),
      TileCoordinate(x * 2 + 1, y * 2 + 1, z + 1),
    ]) {
      if (depth == 1) {
        yield child;
      } else {
        yield* child.traverseChildren(depth - 1);
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      other is TileCoordinate && x == other.x && y == other.y && z == other.z;
  @override
  int get hashCode => Object.hash(x, y, z);
}

/// Geographic subdivision matching Takram's TilingScheme, not Web Mercator.
final class TilingScheme {
  final int width, height;
  final GeographicRectangle rectangle;
  TilingScheme({
    this.width = 2,
    this.height = 1,
    this.rectangle = GeographicRectangle.maximum,
  }) {
    if (width <= 0 ||
        height <= 0 ||
        width > 1 << 30 ||
        height > 1 << 30 ||
        rectangle.toList().any((v) => !v.isFinite) ||
        rectangle.width <= 0 ||
        rectangle.height <= 0) {
      throw ArgumentError(
        'Tiling dimensions and rectangle extents must be positive and finite.',
      );
    }
  }

  /// Native integer sizes do not reproduce JavaScript's signed shift overflow.
  ({int width, int height}) getSize(int z) {
    if (z < 0 || z > 30) throw RangeError.range(z, 0, 30, 'z');
    return (width: width * (1 << z), height: height * (1 << z));
  }

  TileCoordinate getTile(Geodetic coordinate, int z) {
    final size = getSize(z);
    var longitude = coordinate.longitude;
    // Preserve the source's unconditional shift for crossing rectangles.
    if (rectangle.east < rectangle.west) longitude += 2 * math.pi;
    final x = ((longitude - rectangle.west) / (rectangle.width / size.width))
        .floor();
    final y =
        ((coordinate.latitude - rectangle.south) /
                (rectangle.height / size.height))
            .floor();
    return TileCoordinate(
      math.min(x, size.width - 1),
      math.min(y, size.height - 1),
      z,
    );
  }

  GeographicRectangle getRectangle(TileCoordinate tile) {
    final size = getSize(tile.z);
    final tileWidth = rectangle.width / size.width;
    final tileHeight = rectangle.height / size.height;
    return GeographicRectangle(
      tile.x * tileWidth + rectangle.west,
      rectangle.north - (size.height - tile.y) * tileHeight,
      (tile.x + 1) * tileWidth + rectangle.west,
      rectangle.north - (size.height - tile.y - 1) * tileHeight,
    );
  }
}
