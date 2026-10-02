import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'overlay_test.dart' show OverlayFixture;

void main() {
  test(
    'native water and vectors drape on terrain and retire with its source',
    () async {
      final source = OverlayTerrainSource(
        terrain: OverlayFixture(),
        outputSize: 64,
        overlays: [
          WaterTintOverlay(color: const Color3(0, 0, 1)),
          TerrainPolygonOverlay(
            color: const Color3(0, 1, 0),
            rings: [
              [
                Geodetic(0, -.0003),
                Geodetic(.0003, -.0003),
                Geodetic(.0003, 0),
                Geodetic(0, 0),
              ],
            ],
          ),
        ],
      );
      final terrain = TerrainPlugin(source: source);
      final backend = await NativeBackend.create();
      final scene = Scene()..background = const Color3(0, 0, 0);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: OrthographicCamera(
          position: const Vec3(6380137, 0, 0),
          target: const Vec3(6378137, 0, 0),
          up: const Vec3(0, 0, 1),
          left: -2000,
          right: 2000,
          top: 2000,
          bottom: -2000,
          near: 10,
          far: 5000,
        ),
        backendFactory: () async => backend.createView(),
        plugins: [GeospatialPlugin(), terrain],
      );
      Future<RenderedFrame> render() =>
          engine.render(elapsed: Duration.zero, width: 128, height: 128);
      Future<RenderedFrame> settle() async {
        for (var i = 0; i < 200; i++) {
          await render();
          if (terrain.stats!.activeRequests == 0) return render();
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        throw StateError('Overlay terrain did not settle.');
      }

      try {
        final frame = await settle();
        expect(terrain.failures, isEmpty);
        var red = 0, green = 0, blue = 0;
        for (var i = 0; i < frame.pixels.length; i += 4) {
          final r = frame.pixels[i],
              g = frame.pixels[i + 1],
              b = frame.pixels[i + 2];
          if (r > 150 && g < 30 && b < 30) red++;
          if (g > 150 && r < 30 && b < 30) green++;
          if (b > 150 && r < 30 && g < 30) blue++;
        }
        expect(red, greaterThan(2500));
        expect(green, greaterThan(2500));
        expect(blue, greaterThan(5500));
        expect(terrain.attributions, ['Fixture']);
        terrain.replaceSource(OverlayFixture(water: false));
        final plain = await settle();
        expect(plain.pixels.where((v) => v != 0), isNotEmpty);
        expect(
          (await backend.resourceStats()).residentBytes,
          lessThan(2 * 1024 * 1024),
        );
        print(
          'Overlay Metal: red=$red green=$green blue=$blue; source replacement passed.',
        );
      } finally {
        await engine.dispose();
        expect(scene.children, isEmpty);
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
