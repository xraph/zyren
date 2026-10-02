import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'terrain status settles without requiring another rendered frame',
    () async {
      final backend = await NativeBackend.create();
      final notifications = <TileStreamingStats>[];
      final terrain = TerrainPlugin(
        source: ProceduralTerrainSource(),
        onChanged: notifications.add,
      );
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(
          position: const Vec3(6390137, 0, 0),
          target: const Vec3(6378137, 0, 0),
          up: const Vec3(0, 0, 1),
          far: 30000,
        ),
        backendFactory: () async => backend.createView(),
        plugins: [GeospatialPlugin(), terrain],
      );
      try {
        await engine.render(elapsed: Duration.zero, width: 64, height: 64);
        await Future<void>.delayed(Duration.zero);
        expect(notifications, isNotEmpty);
        expect(notifications.last.activeRequests, 0);
        expect(notifications.last.visibleTiles, 1);
        await engine.dispose();
        final count = notifications.length;
        await Future<void>.delayed(Duration.zero);
        expect(notifications.length, count);
      } finally {
        await engine.dispose();
        await backend.close();
      }
    },
  );

  test(
    'checker magnification stays consistent when terrain detail changes',
    () async {
      final backend = await NativeBackend.create();
      final images = <RenderedFrame>[];
      try {
        for (final level in [0, 1]) {
          final scene = Scene();
          final terrain = TerrainPlugin(
            source: ProceduralTerrainSource(
              maximumLevel: level,
              maximumHeight: 0,
            ),
            maximumScreenError: .00001,
          );
          final engine = await SceneEngine.create(
            scene: scene,
            camera: OrthographicCamera(
              position: const Vec3(6380137, 0, 0),
              target: const Vec3(6378137, 0, 0),
              up: const Vec3(0, 0, 1),
              left: -1500,
              right: 1500,
              top: 1500,
              bottom: -1500,
              near: 10,
              far: 5000,
            ),
            backendFactory: () async => backend.createView(),
            plugins: [GeospatialPlugin(), terrain],
          );
          try {
            for (var i = 0; i < 10; i++) {
              await engine.render(
                elapsed: Duration.zero,
                width: 128,
                height: 128,
              );
              await Future<void>.delayed(Duration.zero);
            }
            expect(terrain.visibleCoordinates.length, level == 0 ? 1 : 4);
            images.add(
              await engine.render(
                elapsed: Duration.zero,
                width: 128,
                height: 128,
              ),
            );
          } finally {
            await engine.dispose();
          }
        }
        var changed = 0;
        for (var i = 0; i < images[0].pixels.length; i += 4) {
          if ((images[0].pixels[i] - images[1].pixels[i]).abs() > 5) changed++;
        }
        expect(
          changed,
          lessThan(200),
          reason:
              'LOD must not change checker edge filtering across entire tiles.',
        );
      } finally {
        await backend.close();
      }
    },
  );

  test(
    'native terrain refines, renders imagery, coarsens and releases resources',
    () async {
      final backend = await NativeBackend.create();
      final source = ProceduralTerrainSource(maximumLevel: 2);
      final terrain = TerrainPlugin(source: source);
      const origin = Vec3(6378137, 0, 0);
      final camera = PerspectiveCamera(
        position: origin + const Vec3(12000, 0, 0),
        target: origin,
        up: const Vec3(0, 0, 1),
        near: 10,
        far: 30000,
      );
      final scene = Scene()..background = const Color3(0, 0, 0);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [GeospatialPlugin(), terrain],
      );
      try {
        Future<RenderedFrame> settle() async {
          var frame = await engine.render(
            elapsed: Duration.zero,
            width: 256,
            height: 192,
          );
          for (var i = 0; i < 30; i++) {
            await Future<void>.delayed(Duration.zero);
            frame = await engine.render(
              elapsed: Duration.zero,
              width: 256,
              height: 192,
            );
            if (terrain.stats!.activeRequests == 0) return frame;
          }
          fail('Terrain did not settle');
        }

        final coarse = await settle();
        expect(terrain.visibleCoordinates, {const TileCoordinate(0, 0, 0)});
        final initialBytes = (await backend.resourceStats()).residentBytes;
        expect(initialBytes, greaterThan(0));
        camera.position = origin + const Vec3(1800, -800, 400);
        final detail = await settle();
        expect(terrain.visibleCoordinates.length, greaterThan(1));
        expect(detail.pixels, isNot(coarse.pixels));
        var colored = 0, green = 0, tan = 0;
        for (var i = 0; i < detail.pixels.length; i += 4) {
          final r = detail.pixels[i],
              g = detail.pixels[i + 1],
              b = detail.pixels[i + 2];
          if (g > 30 && b > 15) colored++;
          if (g > r * 1.2 && g > b * 1.2) green++;
          if (r > g && g > b * 1.2) tan++;
        }
        expect(colored, greaterThan(15000));
        expect(green, greaterThan(1000));
        expect(tan, greaterThan(1000));
        expect(
          terrain.stats!.residentBytes,
          lessThanOrEqualTo(terrain.budget.maxResidentBytes),
        );
        camera.position = origin + const Vec3(12000, 0, 0);
        await settle();
        expect(terrain.visibleCoordinates.length, 1);
        expect((await backend.resourceStats()).residentBytes, initialBytes);
        await engine.render(elapsed: Duration.zero, width: 130, height: 250);
        print(
          'Terrain native imagery: $colored pixels, green=$green tan=$tan; root bytes=$initialBytes',
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

  test('detaching during decode never attaches late terrain', () async {
    final backend = await NativeBackend.create();
    final terrain = TerrainPlugin(
      source: ProceduralTerrainSource(latency: const Duration(seconds: 1)),
    );
    final scene = Scene();
    final engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(
        position: const Vec3(6390137, 0, 0),
        target: const Vec3(6378137, 0, 0),
        up: const Vec3(0, 0, 1),
        far: 30000,
      ),
      backendFactory: () async => backend.createView(),
      plugins: [GeospatialPlugin(), terrain],
    );
    try {
      await engine.render(elapsed: Duration.zero, width: 64, height: 64);
      expect(terrain.stats!.activeRequests, greaterThan(0));
      await engine.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(scene.children, isEmpty);
      expect(terrain.stats, isNull);
      expect((await backend.resourceStats()).residentBytes, 0);
    } finally {
      await engine.dispose();
      await backend.close();
    }
  });
}
