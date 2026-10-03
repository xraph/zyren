import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../terrain/imagery_test.dart' show SolidImagery;
import 'terrain_integration_test.dart' show layerCamera;

void main() {
  test(
    'native atmosphere layer hides composition while retaining lighting data',
    () async {
      final backend = await NativeBackend.create();
      final sky = AtmosphereExtension(
        id: 'sky',
        date: DateTime.utc(2026, 3, 20, 12),
      );
      final geo = GeospatialPlugin(extensions: [sky]);
      final scene = Scene()
        ..renderSettings = RenderSettings(
          hdr: true,
          toneMapping: ToneMapping.aces,
        );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(
          position: const Vec3(6379137, 0, 0),
          target: const Vec3(6379137, 0, 1000),
          up: const Vec3(1, 0, 0),
          near: 1,
          far: 1e8,
        ),
        plugins: geo.scenePlugins,
        backendFactory: () async => backend.createView(),
      );
      int light(RenderedFrame frame) {
        var sum = 0;
        for (var i = 0; i < frame.pixels.length; i++) {
          if (i % 4 != 3) sum += frame.pixels[i];
        }
        return sum;
      }

      try {
        final day = await engine.render(
          elapsed: Duration.zero,
          width: 64,
          height: 48,
        );
        expect(light(day), greaterThan(1000));
        expect(geo.layers.layer('sky').status.data, GeoLayerDataState.ready);
        geo.layers.setVisible('sky', false);
        final hidden = await engine.render(
          elapsed: Duration.zero,
          width: 32,
          height: 64,
        );
        expect(scene.effects, isEmpty);
        expect(light(hidden), 0);
        final lighting = await sky.atmosphere.controller.acquireLighting();
        expect(lighting.luts.isClosed, isFalse);
        await lighting.close();
        await sky.atmosphere.controller.setParameters(
          sky.atmosphere.controller.parameters.copyWith(
            groundAlbedo: const Vec3(.2, .2, .2),
          ),
        );
        expect(scene.effects, isEmpty);
        geo.layers.setVisible('sky', true);
        final restored = await engine.render(
          elapsed: Duration.zero,
          width: 64,
          height: 48,
        );
        expect(light(restored), greaterThan(1000));
        expect(scene.effects, hasLength(1));
      } finally {
        await engine.dispose();
        expect(scene.effects, isEmpty);
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'native imagery layer opacity and order change pixels and release resources',
    () async {
      final backend = await NativeBackend.create();
      final terrain = TerrainExtension(
        id: 'ground',
        source: ProceduralTerrainSource(maximumLevel: 0, maximumHeight: 0),
        imagerySize: 16,
        imagery: [
          GeoImageryLayer(
            id: 'red',
            source: SolidImagery('Red', [255, 0, 0, 255]),
          ),
          GeoImageryLayer(
            id: 'blue',
            source: SolidImagery('Blue', [0, 0, 255, 255]),
          ),
        ],
      );
      final geo = GeospatialPlugin(extensions: [terrain]);
      final scene = Scene()..background = const Color3(0, 0, 0);
      final camera = layerCamera()..position = const Vec3(6381137, 0, 0);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        plugins: geo.scenePlugins,
        backendFactory: () async => backend.createView(),
      );
      Future<RenderedFrame> settle(int width, int height) async {
        for (var i = 0; i < 200; i++) {
          await engine.render(
            elapsed: Duration(milliseconds: i * 16),
            width: width,
            height: height,
          );
          if (terrain.terrain.stats!.activeRequests == 0 &&
              !terrain.terrain.retainingPreviousSource &&
              terrain.terrain.visibleCoordinates.isNotEmpty) {
            return engine.render(
              elapsed: Duration.zero,
              width: width,
              height: height,
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        throw StateError('Native imagery layers did not settle.');
      }

      int channel(RenderedFrame frame, int offset) =>
          frame.pixels[(frame.height ~/ 2 * frame.width + frame.width ~/ 2) *
                  4 +
              offset];
      try {
        final blue = await settle(192, 128);
        expect(channel(blue, 2), greaterThan(channel(blue, 0) + 80));
        geo.layers.transact(
          geo.layers.revision,
          (e) => e.setOpacity('blue', 0),
        );
        final red = await settle(96, 160);
        expect(channel(red, 0), greaterThan(channel(red, 2) + 80));
        expect(terrain.terrain.attributions, ['Red']);
        geo.layers.transact(geo.layers.revision, (e) {
          e.setOpacity('blue', 1);
          e.move('blue', 1);
        });
        final reordered = await settle(192, 128);
        expect(channel(reordered, 0), greaterThan(channel(reordered, 2) + 80));
        geo.layers.setVisible('ground', false);
        final hidden = await engine.render(
          elapsed: Duration.zero,
          width: 96,
          height: 160,
        );
        expect(channel(hidden, 0), 0);
        expect(channel(hidden, 2), 0);
        expect(terrain.terrain.stats!.cachedBytes, greaterThan(0));
        print(
          'Native layers: 192x128 and 96x160; opacity, ordering, hidden cache retention and cleanup verified.',
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
