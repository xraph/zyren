import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'fixtures.dart';
import 'streaming_test.dart' show source;

class _Input implements ViewportInputSource {
  @override
  ViewportMetrics viewport = const ViewportMetrics(
    800,
    600,
    devicePixelRatio: 3,
  );
  @override
  Stream<ScenePointerEvent> get events => const Stream.empty();
  @override
  Registration registerGesture(SceneGesture gesture) => Registration(() {});
}

class _Renderer implements SceneRenderer {
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
    name: 'resolution fixture',
    features: {RenderFeatures.indexedMeshes, RenderFeatures.rgbaReadback},
    maxDimension: 2048,
  );
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) async => RenderedFrame(Uint8List(width * height * 4), width, height);
  @override
  Future<void> dispose() async {}
}

void main() {
  for (final orthographic in [false, true]) {
    test(
      '${orthographic ? 'orthographic' : 'perspective'} tiles refine at render resolution independently of touch dimensions',
      () async {
        final input = _Input();
        final tiles = Tiles3DPlugin(
          tileset: await source(
            tile(
              uri: 'parent',
              error: 1,
              refine: 'REPLACE',
              children: [tile(uri: 'child')],
            ),
          ),
          services: AssetServices(
            resolver: MemoryResolver({
              '/parent': triangleModel(),
              '/child': triangleModel(),
            }),
          ),
        );
        final camera = orthographic
            ? OrthographicCamera(
                position: const Vec3(0, -110, 0),
                target: Vec3.zero,
                up: const Vec3(0, 0, 1),
                left: -66.6667,
                right: 66.6667,
                top: 50,
                bottom: -50,
              )
            : PerspectiveCamera(
                position: const Vec3(0, -110, 0),
                target: Vec3.zero,
                up: const Vec3(0, 0, 1),
              );
        final engine = await SceneEngine.create(
          scene: Scene(),
          camera: camera,
          input: input,
          plugins: [tiles],
          rendererFactory: () async => _Renderer(),
        );
        addTearDown(engine.dispose);

        Future<void> render(int width, int height) async {
          for (var i = 0; i < 100; i++) {
            await engine.render(
              elapsed: Duration.zero,
              width: width,
              height: height,
            );
            if (tiles.stats!.activeRequests == 0) return;
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
          fail('Resolution fixture did not settle.');
        }

        // A capped target must not refine as though all device pixels render.
        await render(800, 600);
        expect(tiles.visibleTileIds, {'0'});
        await render(1600, 1200);
        expect(tiles.visibleTileIds, {'0/0'});
        await render(400, 300);
        expect(tiles.visibleTileIds, {'0'});

        // Resizing the touch surface alone does not change rendered detail.
        input.viewport = const ViewportMetrics(1600, 1200, devicePixelRatio: 3);
        await render(400, 300);
        expect(tiles.visibleTileIds, {'0'});
      },
    );
  }
}
