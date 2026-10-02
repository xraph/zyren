import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../streaming/tile_scheduler_test.dart' show flush;

void main() {
  test(
    'accepted patches next to either pole load with finite normals',
    () async {
      for (final northPole in [true, false]) {
        final edge = math.pi / 2 - 1e-10;
        final source = ProceduralTerrainSource(
          scheme: TilingScheme(
            width: 1,
            rectangle: GeographicRectangle(
              -.001,
              northPole ? edge - .001 : -edge,
              .001,
              northPole ? edge : -edge + .001,
            ),
          ),
        );
        final tile = await source.load(
          const TileCoordinate(0, 0, 0),
          contextFor(source),
        );
        expect(tile.geometry.normals.every((n) => n.isFinite), isTrue);
        for (var i = 0; i < tile.geometry.normals.length; i += 3) {
          final n = tile.geometry.normals;
          expect(Vec3(n[i], n[i + 1], n[i + 2]).length, closeTo(1, 1e-6));
        }
      }
    },
  );

  test(
    'declared bounds contain high-latitude surface and skirt vertices',
    () async {
      final source = ProceduralTerrainSource(
        maximumHeight: 0,
        scheme: TilingScheme(
          width: 1,
          rectangle: GeographicRectangle(0, 1.451, .000001, 1.55),
        ),
      );
      const coordinate = TileCoordinate(0, 0, 0);
      final metadata = source.describe(coordinate);
      final tile = await source.load(coordinate, contextFor(source));
      for (var i = 0; i < tile.geometry.positions.length; i += 3) {
        final position =
            tile.origin +
            Vec3(
              tile.geometry.positions[i],
              tile.geometry.positions[i + 1],
              tile.geometry.positions[i + 2],
            );
        expect(
          (position - metadata.center).length,
          lessThanOrEqualTo(metadata.radius),
        );
      }
    },
  );

  test(
    'fixture payload matches reservation and imagery uses north at V zero',
    () async {
      final source = ProceduralTerrainSource();
      final scheduler = TileScheduler(source: source);
      addTearDown(scheduler.dispose);
      final origin = source.describe(const TileCoordinate(0, 0, 0)).center;
      scheduler.update(
        PerspectiveCamera(
          position: origin + const Vec3(100000, 0, 0),
          target: origin,
          up: const Vec3(0, 0, 1),
          far: 1e7,
        ),
        const ViewportMetrics(800, 600),
      );
      await flush();
      final tile = scheduler.visible.values.single;
      final metadata = source.describe(const TileCoordinate(0, 0, 0));
      expect(tile.decodedBytes, metadata.decodedBytes);
      expect(tile.residentBytes, metadata.residentBytes);
      expect(tile.geometry.uv0!.take(2), [0, 0]);
      expect(tile.geometry.uv0!.skip(source.segments * 2).take(2), [1, 0]);
      expect(tile.imageryRectangle, source.scheme.rectangle);
      expect(tile.geometry.positions.every((p) => p.abs() < 5000), isTrue);
      expect(
        tile.imagery.levels.single.length,
        source.imagerySize * source.imagerySize * 4,
      );
    },
  );

  test(
    'sibling edges match in ECEF below a millimetre, including the dateline',
    () async {
      for (final rectangle in [
        const GeographicRectangle(-.0003, -.0003, .0003, .0003),
        GeographicRectangle(math.pi - .0003, -.0003, -math.pi + .0003, .0003),
      ]) {
        final source = ProceduralTerrainSource(
          scheme: TilingScheme(width: 1, rectangle: rectangle),
        );
        final a = await source.load(
          const TileCoordinate(0, 0, 1),
          contextFor(source),
        );
        final b = await source.load(
          const TileCoordinate(1, 0, 1),
          contextFor(source),
        );
        Vec3 position(TerrainTile tile, int index) =>
            tile.origin +
            Vec3(
              tile.geometry.positions[index * 3],
              tile.geometry.positions[index * 3 + 1],
              tile.geometry.positions[index * 3 + 2],
            );
        var worst = 0.0;
        for (var row = 0; row <= source.segments; row++) {
          final distance =
              (position(a, row * (source.segments + 1) + source.segments) -
                      position(b, row * (source.segments + 1)))
                  .length;
          worst = math.max(worst, distance);
          expect(distance, lessThan(.001));
        }
        // A skirt vertex must lie below its surface edge, closing mixed LOD cracks.
        final firstSkirt = (source.segments + 1) * (source.segments + 1);
        expect(
          (position(a, 0) - position(a, firstSkirt)).length,
          closeTo(source.skirtDepth, .001),
        );
        print('Terrain shared-edge error: $worst m');
      }
    },
  );

  test(
    'surface normals follow terrain slope and triangles face outward',
    () async {
      final source = ProceduralTerrainSource();
      final tile = await source.load(
        const TileCoordinate(0, 0, 0),
        contextFor(source),
      );
      final p = tile.geometry.positions, n = tile.geometry.normals;
      Vec3 v(List<double> values, int i) =>
          Vec3(values[i * 3], values[i * 3 + 1], values[i * 3 + 2]);
      for (var i = 0; i < source.segments * source.segments * 6; i += 3) {
        final ids = tile.geometry.indices.skip(i).take(3).toList();
        final normal = (v(p, ids[1]) - v(p, ids[0])).cross(
          v(p, ids[2]) - v(p, ids[0]),
        );
        expect(
          normal.dot(source.ellipsoid.surfaceNormal(tile.origin)),
          greaterThan(0),
        );
        expect(normal.normalized().dot(v(n, ids[0])), greaterThan(.8));
      }
    },
  );

  test(
    'source enforces cancellation, dimensions and byte budget before decoding',
    () async {
      final source = ProceduralTerrainSource();
      await expectLater(
        source.load(
          const TileCoordinate(0, 0, 0),
          TileLoadContext(
            sourceIdentity: source.identity,
            cancellation: Cancelled(),
            byteBudget: 100,
          ),
        ),
        throwsA(isA<LoadCancelled>()),
      );
      await expectLater(
        source.load(
          const TileCoordinate(0, 0, 0),
          TileLoadContext(
            sourceIdentity: source.identity,
            cancellation: Live(),
            byteBudget: 100,
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => source.describe(const TileCoordinate(4, 0, 1)),
        throwsRangeError,
      );
      expect(() => ProceduralTerrainSource(segments: 0), throwsArgumentError);
    },
  );
}

TileLoadContext contextFor(ProceduralTerrainSource source) => TileLoadContext(
  sourceIdentity: source.identity,
  cancellation: Live(),
  byteBudget: 1024 * 1024,
);

class Live implements LoadCancellation {
  @override
  bool get isCancelled => false;
  @override
  Registration onCancel(void Function() callback) => Registration(() {});
  @override
  void throwIfCancelled() {}
}

class Cancelled extends Live {
  @override
  bool get isCancelled => true;
  @override
  void throwIfCancelled() => throw LoadCancelled();
}
