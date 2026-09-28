import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
// Share the synthetic HTTP dataset with the Flutter lab.
// ignore: avoid_relative_lib_imports
import '../../../examples/planet/lib/tiles3d_fixture.dart';

void main() {
  test(
    'HTTP GLB and b3dm stream through native Metal with fallback and cleanup',
    () async {
      final fixture = await Tiles3DFixture.start(latency: Duration.zero);
      addTearDown(fixture.close);
      final services = AssetServices(
        resolver: const NativeSourceResolver(),
        imageDecoder: const NativeImageDecoder(),
      );
      final assets = AssetScope(services: services);
      addTearDown(assets.close);
      final tileset = await assets.load(Tiles3D.tileset(fixture.uri)).result;
      final tiles = Tiles3DPlugin(tileset: tileset, services: services);
      final backend = await NativeBackend.create();
      const origin = Vec3(6378137, 0, 0);
      final camera = PerspectiveCamera(
        position: origin + const Vec3(1500, -900, 900),
        target: origin,
        up: const Vec3(1, 0, 0),
        near: .1,
        far: 1e9,
        depthStrategy: DepthStrategy.reversed,
      );
      final scene = Scene()..background = const Color3(0, 0, 0);
      final light = DirectionalLight(
        direction: const Vec3(-1, .4, -.8),
        intensity: 3,
      );
      scene.add(light);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [tiles],
      );
      try {
        Future<RenderedFrame> settle() async {
          for (var i = 0; i < 200; i++) {
            final frame = await engine.render(
              elapsed: Duration.zero,
              width: 256,
              height: 192,
            );
            if (tiles.stats!.activeRequests == 0) return frame;
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          throw StateError('3D Tiles did not settle.');
        }

        await settle();
        expect(tiles.visibleTileIds, {'0'});
        fixture.failChildren = true;
        camera.position = origin + const Vec3(450, -450, 350);
        await settle();
        expect(tiles.visibleTileIds, {'0'});
        expect(tiles.failures, isNotEmpty);
        fixture.failChildren = false;
        tiles.retryFailed();
        final frame = await settle();
        expect(tiles.visibleTileIds.length, greaterThan(1));
        expect(tiles.visibleTileIds, isNot(contains('0')));
        var colored = 0;
        for (var i = 0; i < frame.pixels.length; i += 4) {
          if (frame.pixels[i] > 30 && frame.pixels[i + 1] > 30) colored++;
        }
        expect(colored, greaterThan(500));
        await engine.render(elapsed: Duration.zero, width: 130, height: 250);
        tiles.replaceTileset(tileset);
        expect(tiles.visibleTileIds, isEmpty);
        await settle();
        print(
          '3D Tiles Metal: $colored pixels; ${tiles.visibleTileIds.length} detail tiles; ${fixture.requests} HTTP content requests.',
        );
      } finally {
        await engine.dispose();
        expect(scene.children, [light]);
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
