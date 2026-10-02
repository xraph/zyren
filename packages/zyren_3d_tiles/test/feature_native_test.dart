import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'feature_test.dart' show batchModel;
import 'fixtures.dart' show MemoryResolver, tile;
import 'streaming_test.dart' show source;
import '../../zyren_gltf/test/metadata_test.dart' show metadataFeatureModel;

void main() {
  for (final modern in [false, true]) {
    test(
      'native ${modern ? 'structural' : 'batch'} feature styles, picking and cleanup',
      () async {
        final backend = await NativeBackend.create();
        final scene = Scene()..background = const Color3(0, 0, 0);
        final tiles = Tiles3DPlugin(
          tileset: await source(tile(refine: 'REPLACE', uri: 'features')),
          services: AssetServices(
            resolver: MemoryResolver({
              '/features': modern ? metadataFeatureModel() : batchModel(),
            }),
          ),
          style: TileStyle3D(
            (feature) => TileFeatureStyle3D(
              color: (feature.properties['height'] as num) < 20
                  ? const Color3(1, 0, 0)
                  : const Color3(0, 0, 1),
            ),
          ),
        );
        final engine = await SceneEngine.create(
          scene: scene,
          camera: OrthographicCamera(
            left: -2.5,
            right: 2.5,
            top: 1.5,
            bottom: -1.5,
            near: .1,
            far: 30,
            position: const Vec3(0, -5, 0),
            up: const Vec3(0, 0, 1),
          ),
          backendFactory: () async => backend.createView(),
          plugins: [tiles],
        );
        Future<RenderedFrame> render() =>
            engine.render(elapsed: Duration.zero, width: 160, height: 96);
        (int, int) colors(List<int> pixels) {
          var red = 0, blue = 0;
          for (var i = 0; i < pixels.length; i += 4) {
            if (pixels[i] > 200 && pixels[i + 2] < 30) red++;
            if (pixels[i + 2] > 200 && pixels[i] < 30) blue++;
          }
          return (red, blue);
        }

        try {
          for (var i = 0; i < 200; i++) {
            await render();
            if (tiles.stats!.activeRequests == 0 &&
                tiles.visibleTileIds.isNotEmpty) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(tiles.failures, isEmpty);
          final counts = colors((await render()).pixels);
          expect(counts.$1, greaterThan(1000));
          expect(counts.$2, greaterThan(1000));
          final ray = CameraRay(const Vec3(-1, -3, 0), const Vec3(0, 1, 0));
          final hit = Raycaster().intersectScene(scene, ray).single;
          expect(tiles.featureFor(hit)!.properties['name'], 'North');
          tiles.setStyle(
            TileStyle3D(
              (feature) => TileFeatureStyle3D(
                show: feature.id == 1,
                color: const Color3(0, 0, 1),
              ),
            ),
          );
          final changed = await engine.renderFrame(
            elapsed: Duration.zero,
            width: 160,
            height: 96,
          );
          expect(changed.stats.uploadedBytes, 0);
          final hidden = colors((changed as ReadbackOutput).image.pixels);
          expect(hidden, (0, counts.$2));
          expect(Raycaster().intersectScene(scene, ray), isEmpty);
          tiles.setStyle(null);
          await render();
          expect(Raycaster().intersectScene(scene, ray), hasLength(1));
          print(
            'Feature Metal: ${counts.$1} red, ${counts.$2} blue; hidden feature unpickable; geometry retained.',
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
}
