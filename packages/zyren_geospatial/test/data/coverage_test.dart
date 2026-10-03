import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'resolver_test.dart' show error;

GeoResourceKey tileKey(TileCoordinate tile) => GeoResourceKey(
  sourceId: 'tiles',
  sourceVersion: '1',
  authorizationPartition: 'public',
  address: '${tile.z}/${tile.x}/${tile.y}',
  representation: 'tile',
  decoderVersion: 1,
);
GeoOfflineRegion region(GeographicRectangle bounds, {int maximumLevel = 2}) =>
    GeoOfflineRegion(
      id: 'region',
      sourceVersions: {'tiles': '1'},
      authorizationPartition: 'public',
      layerIds: {'map'},
      bounds: bounds,
      minimumLevel: 0,
      maximumLevel: maximumLevel,
    );
GeoTileRegionSource source({
  ImageryProjection projection = ImageryProjection.geographic,
  bool known = true,
  bool allowGlobal = false,
}) => GeoTileRegionSource(
  metadata: GeoSourceMetadata(
    sourceId: 'tiles',
    sourceVersion: '1',
    mayPersist: true,
    mayExportOffline: true,
  ),
  coverage: GeoCoverage(
    rectangles: [GeographicRectangle.maximum],
    known: known,
  ),
  projection: projection,
  keyForTile: tileKey,
  estimatedTileBytes: 32,
  allowGlobal: allowGlobal,
);
void main() {
  test('unbounded resource enumerables stop at the declared plan limit', () {
    var generated = 0;
    Iterable<GeoPlannedResource> endless() sync* {
      while (true) {
        generated++;
        yield GeoPlannedResource(
          key: tileKey(TileCoordinate(generated, 0, 20)),
          estimatedBytes: 1,
        );
      }
    }

    expect(
      () => GeoRegionPlan(
        region: region(const GeographicRectangle(0, 0, .1, .1)),
        resources: endless(),
        coverageComplete: true,
        maxResources: 4,
      ),
      error(GeoDataError.budgetExceeded),
    );
    expect(generated, 5);
  });

  test(
    'coverage splits the antimeridian and detects holes between rectangles',
    () {
      final covered = GeoCoverage(
        rectangles: [
          const GeographicRectangle(3, 0, math.pi, .5),
          const GeographicRectangle(-math.pi, 0, -3, .5),
        ],
      );
      expect(
        covered.covers(
          const GeographicRectangle(3.1, .1, -3.1, .4),
          minimumLevel: 0,
          maximumLevel: 2,
        ),
        isTrue,
      );
      expect(covered.contains(Geodetic(0, .2)), isFalse);
      final hole = GeoCoverage(
        rectangles: [
          const GeographicRectangle(0, 0, .4, 1),
          const GeographicRectangle(.6, 0, 1, 1),
        ],
      );
      expect(
        hole.covers(
          const GeographicRectangle(0, 0, 1, 1),
          minimumLevel: 0,
          maximumLevel: 0,
        ),
        isFalse,
      );
    },
  );
  test(
    'Mercator tiles and unknown coverage cannot certify the poles',
    () async {
      final catalog = GeoSourceCatalog()
        ..register(source(projection: ImageryProjection.webMercator));
      final result = await catalog.plan(
        region(const GeographicRectangle(0, 1.4, .1, math.pi / 2)),
      );
      expect(result.coverageComplete, isFalse);
      final unknown = GeoSourceCatalog()..register(source(known: false));
      expect(
        (await unknown.plan(
          region(const GeographicRectangle(0, 0, .1, .1)),
        )).coverageComplete,
        isFalse,
      );
    },
  );
  test(
    'oversized and global requests fail before any download can start',
    () async {
      final catalog = GeoSourceCatalog()..register(source());
      await expectLater(
        catalog.plan(region(GeographicRectangle.maximum)),
        error(GeoDataError.budgetExceeded),
      );
      await expectLater(
        catalog.plan(
          region(const GeographicRectangle(-2, -1, 2, 1), maximumLevel: 24),
          limits: const GeoRegionLimits(maxResources: 4, maxBytes: 100000),
        ),
        error(GeoDataError.budgetExceeded),
      );
      final small = await catalog.plan(
        region(const GeographicRectangle(3.1, 0, -3.1, .1), maximumLevel: 2),
      );
      expect(
        small.resources.map((r) => r.key).toSet().length,
        small.resources.length,
      );
      expect(
        small.resources.any((r) => r.key.address.startsWith('0/')),
        isTrue,
      );
    },
  );
}
