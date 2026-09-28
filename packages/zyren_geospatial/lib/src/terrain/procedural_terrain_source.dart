import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../geodesy.dart';
import '../tiling.dart';
import '../streaming/tile_source.dart';
import 'terrain_tile.dart';

/// Offline fixture with analytic hills, aligned checker imagery and edge skirts.
/// Regional patches only. This source does not model real terrain or providers.
class ProceduralTerrainSource implements TerrainSource {
  final TilingScheme scheme;
  @override
  final Ellipsoid ellipsoid;
  final int segments, imagerySize, maximumLevel;
  final double maximumHeight, skirtDepth;
  final Duration latency;
  @override
  late final String identity;
  ProceduralTerrainSource({
    TilingScheme? scheme,
    this.ellipsoid = Ellipsoid.wgs84,
    this.segments = 16,
    this.imagerySize = 32,
    this.maximumLevel = 3,
    this.maximumHeight = 300,
    this.skirtDepth = 80,
    this.latency = Duration.zero,
  }) : scheme =
           scheme ??
           TilingScheme(
             width: 1,
             rectangle: const GeographicRectangle(-.0003, -.0003, .0003, .0003),
           ) {
    final rectangle = this.scheme.rectangle;
    if (this.scheme.width != 1 ||
        this.scheme.height != 1 ||
        segments < 2 ||
        segments > 128 ||
        imagerySize < 2 ||
        imagerySize > 256 ||
        maximumLevel < 0 ||
        maximumLevel > 12 ||
        !maximumHeight.isFinite ||
        maximumHeight < 0 ||
        !skirtDepth.isFinite ||
        skirtDepth <= 0 ||
        latency.isNegative ||
        rectangle.width > .1 ||
        rectangle.height > .1 ||
        rectangle.north >= math.pi / 2 ||
        rectangle.south <= -math.pi / 2) {
      throw ArgumentError('Invalid regional terrain fixture dimensions.');
    }
    identity =
        'procedural-terrain:v1:${rectangle.toList().join(',')}:'
        '${ellipsoid.x},${ellipsoid.y},${ellipsoid.z}:'
        '$segments:$imagerySize:$maximumLevel:$maximumHeight:$skirtDepth';
  }
  @override
  Iterable<TileCoordinate> get roots => const [TileCoordinate(0, 0, 0)];
  int get _vertices => (segments + 1) * (segments + 1) + 4 * segments;
  int get _indices => segments * segments * 6 + 4 * segments * 6;
  int get _imageBytes => imagerySize * imagerySize * 4;
  int get _textureBytes => TextureDescriptor(
    width: imagerySize,
    height: imagerySize,
    mipLevels: imagerySize.bitLength,
  ).byteLength;

  @override
  TileMetadata describe(TileCoordinate coordinate) {
    if (coordinate.z < 0 ||
        coordinate.z > maximumLevel ||
        coordinate.x < 0 ||
        coordinate.y < 0 ||
        coordinate.x >= 1 << coordinate.z ||
        coordinate.y >= 1 << coordinate.z) {
      throw RangeError('Tile is outside this terrain source.');
    }
    final rect = scheme.getRectangle(coordinate);
    final size = 1 << coordinate.z;
    // Geodetic angles describe surface normals. A flattened ellipsoid's
    // surface derivative can exceed its largest radius.
    final angularScale =
        ellipsoid.maximumRadius *
        ellipsoid.maximumRadius /
        ellipsoid.minimumRadius;
    final cell = math.max(rect.width, rect.height) * angularScale / segments;
    final error =
        maximumHeight *
            4 *
            math.pi *
            math.pi /
            (segments * segments * size * size) +
        cell * cell / ellipsoid.minimumRadius;
    return TileMetadata(
      coordinate: coordinate,
      center: ellipsoid.toEcef(
        Geodetic(rect.west + rect.width / 2, (rect.south + rect.north) / 2),
      ),
      radius:
          angularScale * (rect.width + rect.height) / 2 +
          maximumHeight +
          skirtDepth,
      geometricError: coordinate.z == maximumLevel ? 0 : error,
      decodedBytes: _vertices * 32 + _indices * 4 + _imageBytes,
      residentBytes: _vertices * 40 + _indices * 4 + _textureBytes,
      children: coordinate.z == maximumLevel
          ? const []
          : coordinate.traverseChildren(1),
    );
  }

  double heightAt(double u, double v) =>
      maximumHeight *
      math.pow(math.sin(math.pi * u) * math.sin(math.pi * v), 2);

  Vec3 _point(double u, double v, [double lowering = 0]) {
    final rect = scheme.rectangle;
    return ellipsoid.toEcef(
      Geodetic(
        rect.west + rect.width * u,
        rect.north - rect.height * v,
        heightAt(u, v) - lowering,
      ),
    );
  }

  @override
  Future<TerrainTile> load(
    TileCoordinate coordinate,
    TileLoadContext context,
  ) async {
    context.cancellation.throwIfCancelled();
    final metadata = describe(coordinate);
    if (context.sourceIdentity != identity ||
        context.byteBudget < metadata.decodedBytes) {
      throw ArgumentError(
        'Terrain load identity or byte reservation does not match.',
      );
    }
    if (latency > Duration.zero) {
      final wait = Completer<void>();
      final timer = Timer(latency, wait.complete);
      final subscription = context.cancellation.onCancel(() {
        timer.cancel();
        if (!wait.isCompleted) wait.completeError(LoadCancelled());
      });
      try {
        await wait.future;
      } finally {
        timer.cancel();
        subscription.dispose();
      }
    }
    context.cancellation.throwIfCancelled();
    final size = 1 << coordinate.z;
    final origin = metadata.center;
    final positions = <double>[], normals = <double>[], uv = <double>[];
    final indices = <int>[];
    void vertex(int x, int y, [double lowering = 0]) {
      final u = (coordinate.x + x / segments) / size;
      final v = (size - coordinate.y - 1 + y / segments) / size;
      final p = _point(u, v, lowering);
      const step = .00001;
      // One-sided derivatives at dataset edges also stay inside the poles.
      final east =
          _point(math.min(1, u + step), v) - _point(math.max(0, u - step), v);
      final south =
          _point(u, math.min(1, v + step)) - _point(u, math.max(0, v - step));
      positions.addAll((p - origin).storage);
      normals.addAll(south.cross(east).normalized().storage);
      uv.addAll([x / segments, y / segments]);
    }

    for (var y = 0; y <= segments; y++) {
      for (var x = 0; x <= segments; x++) {
        vertex(x, y);
      }
    }
    for (var y = 0; y < segments; y++) {
      for (var x = 0; x < segments; x++) {
        final a = y * (segments + 1) + x, b = a + segments + 1;
        indices.addAll([a, b, a + 1, a + 1, b, b + 1]);
      }
    }
    final edge = <(int, int)>[
      for (var x = 0; x < segments; x++) (x, 0),
      for (var y = 0; y < segments; y++) (segments, y),
      for (var x = segments; x > 0; x--) (x, segments),
      for (var y = segments; y > 0; y--) (0, y),
    ];
    final firstSkirt = positions.length ~/ 3;
    for (final (x, y) in edge) {
      vertex(x, y, skirtDepth);
    }
    for (var i = 0; i < edge.length; i++) {
      final next = (i + 1) % edge.length;
      final (x, y) = edge[i];
      final (nx, ny) = edge[next];
      final a = y * (segments + 1) + x, b = ny * (segments + 1) + nx;
      indices.addAll([
        a,
        b,
        firstSkirt + i,
        b,
        firstSkirt + next,
        firstSkirt + i,
      ]);
    }
    final pixels = Uint8List(_imageBytes);
    for (var y = 0; y < imagerySize; y++) {
      for (var x = 0; x < imagerySize; x++) {
        final u = (coordinate.x + (x + .5) / imagerySize) / size;
        final v = (size - coordinate.y - 1 + (y + .5) / imagerySize) / size;
        final alternate = ((u * 16).floor() + (v * 16).floor()).isEven;
        final offset = (y * imagerySize + x) * 4;
        pixels.setRange(
          offset,
          offset + 4,
          alternate ? [65, 136, 87, 255] : [191, 171, 113, 255],
        );
      }
    }
    return TerrainTile(
      origin: origin,
      geometry: BufferGeometry(
        positions: positions,
        normals: normals,
        uv0: uv,
        indices: indices,
      ),
      imagery: TextureImage.rgba(
        width: imagerySize,
        height: imagerySize,
        pixels: pixels,
        generateMipmaps: true,
      ),
      imageryRectangle: scheme.getRectangle(coordinate),
      sampler: const SamplerDescriptor(
        minFilter: TextureFilter.nearest,
        magFilter: TextureFilter.nearest,
      ),
    );
  }
}
