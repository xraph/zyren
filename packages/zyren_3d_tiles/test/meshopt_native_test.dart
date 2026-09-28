import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'package:zyren_native/zyren_native.dart';
import 'fixtures.dart';

void main() {
  test('meshopt tile streams, renders and releases native geometry', () async {
    final source = MemoryResolver({
      '/tileset.json': tilesetBytes(
        tile(uri: 'triangle.glb', refine: 'REPLACE'),
      ),
      '/triangle.glb': await File(
        '../../test_assets/compression/triangle.glb',
      ).readAsBytes(),
    });
    final services = AssetServices(
      resolver: source,
      bufferDecoder: const NativeBufferDecoder(),
    );
    final assets = AssetScope(services: services);
    addTearDown(assets.close);
    final tileset = await assets
        .load(Tiles3D.tileset(Uri.parse('https://tiles.test/tileset.json')))
        .result;
    final tiles = Tiles3DPlugin(tileset: tileset, services: services);
    final backend = await NativeBackend.create();
    final scene = Scene()..background = const Color3(0, 0, 0);
    final engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(
        position: const Vec3(0, -3, 0),
        up: const Vec3(0, 0, 1),
      ),
      backendFactory: () async => backend.createView(),
      plugins: [tiles],
    );
    try {
      RenderedFrame? frame;
      for (var i = 0; i < 200; i++) {
        frame = await engine.render(
          elapsed: Duration.zero,
          width: 128,
          height: 128,
        );
        if (tiles.stats!.activeRequests == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(tiles.failures, isEmpty);
      expect(tiles.visibleTileIds, {'0'});
      var red = 0;
      for (var i = 0; i < frame!.pixels.length; i += 4) {
        if (frame.pixels[i] > 200 &&
            frame.pixels[i + 1] < 20 &&
            frame.pixels[i + 2] < 20) {
          red++;
        }
      }
      expect(red, greaterThan(500));
      print(
        'Meshopt native tile: $red red pixels; ${source.reads.length} source reads.',
      );
    } finally {
      await engine.dispose();
      expect(scene.children, isEmpty);
      expect((await backend.resourceStats()).residentBytes, 0);
      await backend.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
