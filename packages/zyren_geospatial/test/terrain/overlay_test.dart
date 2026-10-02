import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial/src/terrain/terrain_pixels.dart';
import 'quantized_mesh_fixture.dart' show TestCancellation;

class OverlayFixture implements TerrainSource {
  final ProceduralTerrainSource base;
  final bool water;
  bool underreport = false;
  Completer<void>? gate;
  int reads = 0;
  TerrainTile? last;
  OverlayFixture({this.water = true, GeographicRectangle? rectangle})
    : base = ProceduralTerrainSource(
        maximumLevel: 0,
        maximumHeight: 0,
        scheme: rectangle == null
            ? null
            : TilingScheme(width: 1, rectangle: rectangle),
      );
  @override
  String get identity => 'overlay-fixture';
  @override
  Ellipsoid get ellipsoid => base.ellipsoid;
  @override
  Iterable<TileCoordinate> get roots => base.roots;
  @override
  TileMetadata describe(TileCoordinate coordinate) {
    final m = base.describe(coordinate);
    return TileMetadata(
      coordinate: coordinate,
      center: m.center,
      radius: m.radius,
      geometricError: m.geometricError,
      decodedBytes: underreport ? 1 : m.decodedBytes + 70000,
      residentBytes: m.residentBytes,
    );
  }

  @override
  Future<TerrainTile> load(
    TileCoordinate coordinate,
    TileLoadContext context,
  ) async {
    reads++;
    await gate?.future;
    final tile = await base.load(
      coordinate,
      TileLoadContext(
        sourceIdentity: base.identity,
        cancellation: context.cancellation,
        byteBudget: base.describe(coordinate).decodedBytes,
      ),
    );
    return last = TerrainTile(
      origin: tile.origin,
      geometry: tile.geometry,
      imageryRectangle: tile.imageryRectangle,
      imagery: TextureImage.rgba(
        width: 1,
        height: 1,
        pixels: Uint8List.fromList([255, 0, 0, 255]),
      ),
      waterMask: water
          ? TerrainWaterMask(
              Uint8List.fromList([
                for (var y = 0; y < 256; y++)
                  for (var x = 0; x < 256; x++) y < 128 ? 255 : 0,
              ]),
            )
          : null,
      availability: TerrainAvailabilityMetadata([]),
      attributions: ['Fixture'],
    );
  }
}

Future<TerrainTile> overlayLoad(
  TerrainSource source, {
  LoadCancellation? cancellation,
}) => source.load(
  const TileCoordinate(0, 0, 0),
  TileLoadContext(
    sourceIdentity: source.identity,
    cancellation: cancellation ?? TestCancellation(),
    byteBudget: source.describe(const TileCoordinate(0, 0, 0)).decodedBytes,
  ),
);
List<int> pixel(TerrainTile tile, int x, int y) {
  final at = (y * tile.imagery.descriptor.width + x) * 4;
  return tile.imagery.levels.first.sublist(at, at + 4);
}

List<Geodetic> square(double extent) => [
  Geodetic(-extent, -extent),
  Geodetic(extent, -extent),
  Geodetic(extent, extent),
  Geodetic(-extent, extent),
];
void main() {
  test('oversized base payload is rejected before worker copies', () async {
    final base = OverlayFixture()..underreport = true;
    final source = OverlayTerrainSource(
      terrain: base,
      overlays: [WaterTintOverlay(color: const Color3(0, 0, 1))],
    );
    await expectLater(
      overlayLoad(source),
      throwsA(
        isA<AssetLoadException>().having(
          (e) => e.code,
          'code',
          AssetLoadError.limitExceeded,
        ),
      ),
    );
  });

  test(
    'composition queue is bounded and cancellation retains physical admission',
    () async {
      final a = Completer<int>(), b = Completer<int>();
      final cancel = TestCancellation();
      var started = 0;
      final first = TerrainCompositionPool.run(() {
        started++;
        return a.future;
      }, cancel);
      final firstCheck = expectLater(first, throwsA(isA<LoadCancelled>()));
      final second = TerrainCompositionPool.run(() {
        started++;
        return b.future;
      }, TestCancellation());
      final queued = [
        for (var i = 0; i < 16; i++)
          TerrainCompositionPool.run(() async {
            started++;
            return i;
          }, TestCancellation()),
      ];
      await expectLater(
        TerrainCompositionPool.run(() async => 99, TestCancellation()),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
      cancel.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(started, 2);
      a.complete(1);
      b.complete(2);
      await firstCheck;
      expect(await second, 2);
      expect(await Future.wait(queued), List.generate(16, (i) => i));
    },
  );

  test(
    'water tint uses north-first coverage and preserves terrain identity data',
    () async {
      final base = OverlayFixture();
      final source = OverlayTerrainSource(
        terrain: base,
        outputSize: 32,
        overlays: [WaterTintOverlay(color: const Color3(0, 0, 1), opacity: .5)],
      );
      final tile = await overlayLoad(source);
      expect(pixel(tile, 8, 8), [188, 0, 188, 255]);
      expect(pixel(tile, 8, 24), [255, 0, 0, 255]);
      expect(tile.geometry, same(base.last!.geometry));
      expect(tile.waterMask, same(base.last!.waterMask));
      expect(tile.availability, same(base.last!.availability));
      expect(tile.attributions, ['Fixture']);
      final metadata = source.describe(const TileCoordinate(0, 0, 0));
      expect(tile.decodedBytes, lessThanOrEqualTo(metadata.decodedBytes));
      expect(tile.residentBytes, lessThanOrEqualTo(metadata.residentBytes));
    },
  );
  test('ordered polygons preserve holes and lines drape over them', () async {
    final polygon = TerrainPolygonOverlay(
      rings: [square(.00025), square(.0001)],
      color: const Color3(0, 1, 0),
    );
    final base = OverlayFixture(water: false);
    final tile = await overlayLoad(
      OverlayTerrainSource(terrain: base, outputSize: 32, overlays: [polygon]),
    );
    expect(pixel(tile, 5, 5), [0, 255, 0, 255]);
    expect(pixel(tile, 16, 16), [255, 0, 0, 255]);
    expect(pixel(tile, 0, 0), [255, 0, 0, 255]);
    final line = TerrainPolylineOverlay(
      points: [Geodetic(-.0002, 0), Geodetic(.0002, 0)],
      color: const Color3(0, 0, 1),
      width: 4,
    );
    final above = await overlayLoad(
      OverlayTerrainSource(
        terrain: base,
        outputSize: 32,
        overlays: [polygon, line],
      ),
    );
    expect(pixel(above, 16, 16), [0, 0, 255, 255]);
    expect(() => polygon.rings.first.clear(), throwsUnsupportedError);
    expect(() => line.points.clear(), throwsUnsupportedError);
  });
  test(
    'dateline vectors take the short path and clip at terrain edges',
    () async {
      final d = math.pi / 180;
      final base = OverlayFixture(
        water: false,
        rectangle: GeographicRectangle(
          179.99 * d,
          -.01 * d,
          -179.99 * d,
          .01 * d,
        ),
      );
      final tile = await overlayLoad(
        OverlayTerrainSource(
          terrain: base,
          outputSize: 32,
          overlays: [
            TerrainPolylineOverlay(
              points: [
                Geodetic.degrees(179.995, 0),
                Geodetic.degrees(-179.995, 0),
              ],
              color: const Color3(0, 0, 1),
              width: 4,
            ),
          ],
        ),
      );
      expect(pixel(tile, 16, 16), [0, 0, 255, 255]);
      expect(pixel(tile, 1, 16), [255, 0, 0, 255]);
    },
  );
  test('work and input limits reject before requesting terrain', () {
    final base = OverlayFixture();
    expect(
      () => OverlayTerrainSource(
        terrain: base,
        outputSize: 1024,
        maxSampleTests: 1024,
        overlays: [
          TerrainPolygonOverlay(
            rings: [square(.1)],
            color: const Color3(0, 1, 0),
          ),
        ],
      ),
      throwsArgumentError,
    );
    expect(base.reads, 0);
    expect(
      () => TerrainPolylineOverlay(
        points: [Geodetic(0, 0)],
        color: const Color3(0, 0, 1),
      ),
      throwsArgumentError,
    );
    expect(
      () => WaterTintOverlay(color: const Color3(0, 0, 1), opacity: double.nan),
      throwsArgumentError,
    );
  });
  test('canceled terrain work stays owned until the source settles', () async {
    final base = OverlayFixture()..gate = Completer<void>();
    final source = OverlayTerrainSource(
      terrain: base,
      overlays: [WaterTintOverlay(color: const Color3(0, 0, 1))],
    );
    final cancel = TestCancellation();
    var settled = false;
    final result = overlayLoad(
      source,
      cancellation: cancel,
    ).whenComplete(() => settled = true);
    final check = expectLater(result, throwsA(isA<LoadCancelled>()));
    cancel.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    base.gate!.complete();
    await check;
  });
}
