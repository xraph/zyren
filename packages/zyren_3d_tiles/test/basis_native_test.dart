import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'package:zyren_native/zyren_native.dart';
import 'fixtures.dart';

void main() {
  test('Basis tile streams authored mips and releases native textures', () async {
    final source = MemoryResolver({
      '/tileset.json': tilesetBytes(tile(uri: 'quad.glb', refine: 'REPLACE')),
      '/quad.glb': texturedModel(
        minFilter: 9987,
        changes: {
          'extensionsUsed': ['KHR_materials_unlit', 'KHR_texture_basisu'],
          'extensionsRequired': ['KHR_materials_unlit', 'KHR_texture_basisu'],
          'images': [
            {'uri': 'colors.ktx2', 'mimeType': 'image/ktx2'},
          ],
          'textures': [
            {
              'sampler': 0,
              'extensions': {
                'KHR_texture_basisu': {'source': 0},
              },
            },
          ],
        },
      ),
      '/colors.ktx2': await File(
        '../../test_assets/compression/colors-zstd.ktx2',
      ).readAsBytes(),
    });
    final services = AssetServices(
      resolver: source,
      textureDecoder: const NativeTextureDecoder(),
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
      frame = await engine.render(
        elapsed: Duration.zero,
        width: 128,
        height: 128,
      );
      var red = 0, blue = 0;
      for (var i = 0; i < frame.pixels.length; i += 4) {
        if (frame.pixels[i] > 180 &&
            frame.pixels[i + 1] < 60 &&
            frame.pixels[i + 2] < 60) {
          red++;
        }
        if (frame.pixels[i + 2] > 180 && frame.pixels[i] < 60) blue++;
      }
      expect(red, greaterThan(500));
      expect(blue, greaterThan(500));
      expect(source.reads, hasLength(3));
      print(
        'Basis native tile: $red red pixels, $blue blue pixels; ${source.reads.length} source reads.',
      );
    } finally {
      await engine.dispose();
      expect(scene.children, isEmpty);
      expect((await backend.resourceStats()).residentBytes, 0);
      await backend.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
