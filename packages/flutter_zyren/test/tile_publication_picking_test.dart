import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import '../../zyren_3d_tiles/test/fixtures.dart';
import '../../zyren_3d_tiles/test/feature_test.dart' show batchModel;
import '../../zyren_3d_tiles/test/motion_test.dart' show at;
import 'support/backend_fake.dart';
import 'controller_test.dart' show frames, readback, runtime, host;

List<Mesh> meshes(Object3D root) => [
  if (root is Mesh && root.visible) root,
  for (final child in root.renderChildren) ...meshes(child),
];

class _Backend extends FakeBackend {
  late Scene scene;
  bool ready = true;
  List<(int, int)> previous = [];
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    final ids = [for (final mesh in meshes(scene)) (mesh.id, mesh.geometry.id)];
    final publish = ready;
    final output = await super.render(submission);
    if (publish) previous = ids;
    return output.withStats(
      FrameStats(
        frameId: output.stats.frameId,
        physicalSize: output.stats.physicalSize,
        presentationPath: PresentationPath.readback,
        cpuBuildTime: Duration.zero,
        cpuSubmitTime: Duration.zero,
        drawCalls: output.stats.drawCalls,
        triangles: output.stats.triangles,
        readbackBytes: output.stats.readbackBytes,
        uploadedBytes: 0,
        admission: SceneAdmission(
          candidateReady: publish,
          publishedRevision: 1,
          uploadBacklogBytes: publish ? 0 : 1,
          stagedBytes: publish ? 0 : 1,
          presentedIdentities: previous,
        ),
      ),
    );
  }
}

void main() {
  testWidgets('prediction expires after SSE settles and the controller idles', (
    tester,
  ) async {
    final resolver = MemoryResolver({
      '/manifest': tilesetBytes(
        tile(
            refine: 'REPLACE',
            children: [at('visible', 0), at('predicted', 24)],
          )
          ..['boundingVolume'] = {
            'sphere': [0, 0, 0, 100],
          },
      ),
      '/visible': triangleModel(),
      '/predicted': triangleModel(),
    });
    final services = AssetServices(resolver: resolver);
    final assets = AssetScope(services: services);
    final tileset = await assets
        .load(Tiles3D.tileset(Uri.parse('asset:///manifest')))
        .result;
    final scene = Scene();
    final backend = _Backend()
      ..scene = scene
      ..additionalFeatures = {RenderFeature.standardMaterials};
    final camera = OrthographicCamera(
      position: const Vec3(0, -50, 0),
      up: const Vec3(0, 0, 1),
      left: -10,
      right: 10,
      top: 10,
      bottom: -10,
    );
    final controller = SceneController(
      scene: scene,
      camera: camera,
      options: readback,
      runtime: runtime(backend),
    );
    final tiles = Tiles3DPlugin(
      tileset: tileset,
      services: services,
      motionPolicy: const Tiles3DMotionPolicy(
        prediction: Duration(seconds: 1),
        settle: Duration(milliseconds: 50),
      ),
      budget: Tiles3DBudget(
        maxRequests: 2,
        maxPrefetchRequests: 1,
        maxPrefetchTiles: 1,
        maxPrefetchBytes: 1024,
        perTileDecodedBytes: 1024,
      ),
    );
    controller.use(tiles);
    Future<void> tick() async {
      await tester.pump(const Duration(milliseconds: 40));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }

    await tester.pumpWidget(host(SceneView(controller: controller)));
    try {
      for (var i = 0; i < 50 && tiles.visibleTileIds.isEmpty; i++) {
        await tick();
      }
      expect(tiles.visibleTileIds, {'0/0'});
      expect(resolver.reads, isNot(contains('/predicted')));
      camera.position = const Vec3(1, -50, 0);
      camera.target = const Vec3(1, 0, 0);
      await tick();
      camera.position = const Vec3(5, -50, 0);
      camera.target = const Vec3(5, 0, 0);
      for (var i = 0; i < 6; i++) {
        await tick();
      }
      expect(tiles.stats!.activeRequests, 0);
      expect(tiles.stats!.effectiveScreenError, 8);
      expect(tiles.stats!.prefetchedTiles, 1);
      expect(resolver.reads.where((p) => p == '/predicted').length, 1);
      for (var i = 0; i < 24; i++) {
        await tick();
      }
      expect(tiles.stats!.prefetchedTiles, 0);
      expect(tiles.stats!.prefetchBytes, 0);
      final settled = backend.submissions.length;
      for (var i = 0; i < 6; i++) {
        await tick();
      }
      expect(backend.submissions.length, settled);
    } finally {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
      await tester.runAsync(assets.close);
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'controller picks displayed tiles through staging, style changes and publication',
    (tester) async {
      final resolver = MemoryResolver({
        '/manifest': tilesetBytes(
          tile(
            uri: 'parent',
            refine: 'REPLACE',
            error: 10,
            children: [tile(uri: 'child')],
          ),
        ),
        '/parent': batchModel(),
        '/child': batchModel(),
      });
      final services = AssetServices(resolver: resolver);
      final assets = AssetScope(services: services);
      final tileset = await assets
          .load(Tiles3D.tileset(Uri.parse('asset:///manifest')))
          .result;
      final scene = Scene();
      final backend = _Backend()
        ..scene = scene
        ..additionalFeatures = {RenderFeature.standardMaterials};
      final camera = OrthographicCamera(
        position: const Vec3(-1, -5, 0),
        target: const Vec3(-1, 0, 0),
        up: const Vec3(0, 0, 1),
        left: -100,
        right: 100,
        top: 100,
        bottom: -100,
      );
      final controller = SceneController(
        scene: scene,
        camera: camera,
        options: readback,
        runtime: runtime(backend),
      );
      final tiles = Tiles3DPlugin(
        tileset: tileset,
        services: services,
        motionPolicy: const Tiles3DMotionPolicy(),
      );
      controller.use(tiles);
      Future<void> advance() async {
        for (var i = 0; i < 20; i++) {
          await frames(tester);
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          if (tiles.stats != null && tiles.stats!.activeRequests == 0) {
            await frames(tester);
            return;
          }
        }
        fail('Tile decode did not settle.');
      }

      await tester.pumpWidget(host(SceneView(controller: controller)));
      await advance();
      expect(tiles.visibleTileIds, {
        '0',
      }, reason: controller.status.value.toString());
      const point = ViewportPoint(32, 32);
      final old = controller.capturePick(point).intersectFirst()!;
      expect(tiles.featureFor(old)!.properties['name'], 'North');
      backend.ready = false;
      camera.setFrustum(left: -2, right: 2, top: 2, bottom: -2);
      await advance();
      expect(tiles.visibleTileIds, {'0'});
      expect(
        controller.capturePick(point).intersectFirst()!.object,
        same(old.object),
      );
      final frozen = controller.pick(point);
      backend.ready = true;
      await advance();
      final next = controller.capturePick(point).intersectFirst()!;
      expect(next.object, isNot(same(old.object)));
      expect(tiles.visibleTileIds, {'0/0'});
      expect((await frozen)!.object, same(old.object));
      expect(tiles.featureFor(old)!.properties['name'], 'North');
      backend.ready = false;
      tiles.setStyle(TileStyle3D((_) => TileFeatureStyle3D(show: false)));
      await advance();
      expect(
        controller.capturePick(point).intersectFirst()!.object,
        same(next.object),
      );
      scene.clippingPlanes = [
        ClippingPlane(normal: const Vec3(1, 0, 0), offset: 5),
      ];
      expect(controller.capturePick(point).intersectFirst(), isNull);
      scene.clippingPlanes = [];
      camera.layers = LayerMask.only(1);
      expect(controller.capturePick(point).intersectFirst(), isNull);
      camera.layers = LayerMask.all;
      backend.ready = true;
      await advance();
      expect(controller.capturePick(point).intersectFirst(), isNull);
      camera.position = const Vec3(-.9, -5, 0);
      camera.target = const Vec3(-.9, 0, 0);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));
      expect(tiles.stats!.effectiveScreenError, greaterThan(8));
      await advance();
      await advance();
      expect(tiles.stats!.effectiveScreenError, 8);
      final settled = backend.submissions.length;
      await advance();
      expect(
        backend.submissions.length,
        settled,
        reason: 'on-demand view returns to idle',
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
      await assets.close();
      expect(tester.takeException(), isNull);
    },
  );
}
