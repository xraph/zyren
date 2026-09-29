import 'package:zyren/zyren.dart';
import '../streaming/tile_source.dart';
import '../tiling.dart';
import '../geodesy.dart';

abstract interface class TerrainSource implements TileSource<TerrainTile> {
  Ellipsoid get ellipsoid;
}

/// A mesh in metres relative to [origin], with top-left geographic imagery.
final class TerrainTile implements TileContent {
  final Vec3 origin;
  final BufferGeometry geometry;
  final TextureImage imagery;
  final SamplerDescriptor sampler;
  final GeographicRectangle imageryRectangle;
  final List<String> attributions;
  TerrainTile({
    required this.origin,
    required this.geometry,
    required this.imagery,
    required this.imageryRectangle,
    this.sampler = const SamplerDescriptor(),
    List<String> attributions = const [],
  }) : attributions = List.unmodifiable(attributions) {
    if (!origin.isFinite || geometry.isDynamic) {
      throw ArgumentError(
        'Terrain requires a finite origin and immutable geometry.',
      );
    }
  }
  @override
  int get decodedBytes =>
      geometry.attributes.values.fold<int>(
        geometry.indices.length * geometry.indexFormat.bytesPerIndex,
        (bytes, attribute) => bytes + attribute.data.lengthInBytes,
      ) +
      imagery.levels.fold<int>(0, (bytes, level) => bytes + level.length) +
      attributions.fold<int>(0, (bytes, text) => bytes + text.length * 2);
  @override
  int get residentBytes =>
      geometry.capture().gpuByteLength + imagery.descriptor.byteLength;
}
