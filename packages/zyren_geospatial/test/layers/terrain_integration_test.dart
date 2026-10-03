import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../terrain/imagery_test.dart' show SolidImagery;

class LayerTestRenderer implements SceneRenderer {
  @override
  RendererCapabilities get capabilities =>
      RendererCapabilities(name: 'test', features: {}, maxDimension: 512);
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

class ControlledTerrain extends ProceduralTerrainSource {
  Object? failure;
  Completer<void>? gate;
  ControlledTerrain() : super(maximumLevel: 0);
  @override
  Future<TerrainTile> load(
    TileCoordinate coordinate,
    TileLoadContext context,
  ) async {
    await gate?.future;
    context.cancellation.throwIfCancelled();
    if (failure case final error?) throw error;
    return super.load(coordinate, context);
  }
}

PerspectiveCamera layerCamera() => PerspectiveCamera(
  position: const Vec3(6390137, 0, 0),
  target: const Vec3(6378137, 0, 0),
  up: const Vec3(0, 0, 1),
  far: 30000,
);

Future<void> settleLayers(
  SceneEngine engine,
  List<TerrainExtension> extensions,
) async {
  for (var frame = 0; frame < 200; frame++) {
    await engine.render(
      elapsed: Duration(milliseconds: frame * 16),
      width: 64,
      height: 64,
    );
    await Future<void>.delayed(const Duration(milliseconds: 2));
    if (extensions.every(
      (extension) => extension.terrain.stats!.activeRequests == 0,
    )) {
      await engine.render(elapsed: Duration.zero, width: 64, height: 64);
      return;
    }
  }
  throw StateError('Layer terrain did not settle.');
}

void main() {
  test(
    'camera extension owns its controls and rejects competing default rigs',
    () async {
      final camera = GlobeCameraExtension(id: 'camera');
      final geo = GeospatialPlugin(extensions: [camera]);
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: layerCamera(),
        plugins: geo.scenePlugins,
        rendererFactory: () async => LayerTestRenderer(),
      );
      expect(camera.camera.controls, isNotNull);
      await engine.dispose();
      expect(camera.camera.controls, isNull);
      var allocated = false;
      final invalid = GeospatialPlugin(
        extensions: [
          camera,
          GlobeCameraExtension(id: 'second'),
        ],
      );
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: layerCamera(),
          plugins: invalid.scenePlugins,
          rendererFactory: () async {
            allocated = true;
            return LayerTestRenderer();
          },
        ),
        throwsStateError,
      );
      expect(allocated, isFalse);
    },
  );

  test(
    'two terrain instances isolate failures, visibility, queries and cleanup',
    () async {
      final goodSource = ControlledTerrain();
      final badSource = ControlledTerrain()
        ..failure = StateError('fixture source unavailable');
      final coast = TerrainExtension(id: 'coast', source: goodSource);
      final survey = TerrainExtension(id: 'survey', source: badSource);
      final geo = GeospatialPlugin(extensions: [coast, survey]);
      final scene = Scene();
      final camera = layerCamera();
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        rendererFactory: () async => LayerTestRenderer(),
        plugins: geo.scenePlugins,
      );
      try {
        await settleLayers(engine, [coast, survey]);
        expect(scene.children, hasLength(2));
        expect(geo.layers.layer('coast').status.data, GeoLayerDataState.ready);
        expect(
          geo.layers.layer('survey').status.data,
          GeoLayerDataState.failed,
        );
        expect(coast.terrain.group, isNot(same(survey.terrain.group)));
        final ray = CameraRay(
          camera.position,
          (camera.target - camera.position).normalized(),
        );
        final hits = coast.pick(ray);
        expect(hits, isNotEmpty);
        expect(hits.first.layerId, 'coast');
        expect(hits.first.sourceRevision, goodSource.identity);
        final cachedBytes = coast.terrain.stats!.cachedBytes;
        geo.layers.transact(geo.layers.revision, (e) {
          e.setVisible('coast', false);
          e.move('survey', 0);
        });
        await engine.render(elapsed: Duration.zero, width: 64, height: 64);
        expect(coast.terrain.group!.visible, isFalse);
        expect(coast.terrain.stats!.cachedBytes, cachedBytes);
        expect(coast.pick(ray), isEmpty);
        geo.layers.transact(
          geo.layers.revision,
          (e) => e.setPolicies(
            'coast',
            const GeoLayerPolicies(queryWhenHidden: true),
          ),
        );
        expect(coast.pick(ray), isNotEmpty);
        badSource.failure = null;
        survey.retryFailed();
        await settleLayers(engine, [coast, survey]);
        expect(geo.layers.layer('survey').status.data, GeoLayerDataState.ready);
        geo.layers.transact(
          geo.layers.revision,
          (edit) => edit.remove('coast'),
        );
        await engine.render(elapsed: Duration.zero, width: 64, height: 64);
        expect(coast.terrain.group!.visible, isFalse);
        expect(coast.pick(ray), isEmpty);
      } finally {
        await engine.dispose();
      }
      expect(scene.children, isEmpty);
      expect(geo.layers.snapshot, isEmpty);
    },
  );

  test(
    'imagery revisions retain old materials through loading and failures',
    () async {
      final base = ControlledTerrain();
      final extension = TerrainExtension(id: 'ground', source: base);
      final geo = GeospatialPlugin(extensions: [extension]);
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: layerCamera(),
        rendererFactory: () async => LayerTestRenderer(),
        plugins: geo.scenePlugins,
      );
      try {
        await settleLayers(engine, [extension]);
        final original = extension.terrain.group!.children.single as Mesh;
        base.gate = Completer<void>();
        extension.setImageryStack(
          [
            ImageryLayer(SolidImagery('Red', [255, 0, 0, 255])),
          ],
          revision: 1,
          outputSize: 2,
        );
        await engine.render(elapsed: Duration.zero, width: 64, height: 64);
        expect(extension.terrain.group!.children.single, same(original));
        base.failure = StateError('replacement failed');
        base.gate!.complete();
        base.gate = null;
        await settleLayers(engine, [extension]);
        expect(extension.terrain.group!.children.single, same(original));
        expect(geo.layers.layer('ground').status.data, GeoLayerDataState.stale);
        base.failure = null;
        extension.retryFailed();
        await settleLayers(engine, [extension]);
        expect(extension.terrain.group!.children.single, isNot(same(original)));
        expect(extension.terrain.attributions, ['Red']);
        expect(
          () => extension.setImageryStack([], revision: 1),
          throwsStateError,
        );
      } finally {
        await engine.dispose();
      }
    },
  );
}
