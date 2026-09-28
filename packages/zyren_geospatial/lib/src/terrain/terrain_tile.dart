import 'package:zyren/zyren.dart';
import '../streaming/tile_source.dart';
import '../tiling.dart';

/// A mesh in metres relative to [origin], with top-left geographic imagery.
final class TerrainTile implements TileContent {
  final Vec3 origin;
  final BufferGeometry geometry;
  final TextureImage imagery;
  final GeographicRectangle imageryRectangle;
  TerrainTile({
    required this.origin,
    required this.geometry,
    required this.imagery,
    required this.imageryRectangle,
  }) {
    if (!origin.isFinite || geometry.isDynamic) {
      throw ArgumentError(
        'Terrain requires a finite origin and immutable geometry.',
      );
    }
  }
  @override
  int get decodedBytes =>
      geometry.attributes.values.fold(
        geometry.indices.length * geometry.indexFormat.bytesPerIndex,
        (bytes, attribute) => bytes + attribute.data.lengthInBytes,
      ) +
      imagery.levels.fold(0, (bytes, level) => bytes + level.length);
  @override
  int get residentBytes =>
      geometry.capture().gpuByteLength + imagery.descriptor.byteLength;
}
