import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'support/renderer.dart';

void main() {
  test(
    'submitted source revisions survive asynchronous edits and preserve the surface receipt',
    () async {
      final scene = Scene();
      final camera = PerspectiveCamera();
      final backend = _DelayedBackend();
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend,
      );
      addTearDown(engine.dispose);
      final sceneRevision = scene.revision, cameraRevision = camera.revision;
      final rendering = engine.renderFrame(
        elapsed: Duration.zero,
        width: 8,
        height: 12,
        target: SurfaceTarget(backend.surface, 7),
      );
      await backend.started.future;
      scene.add(Group());
      camera.position = const Vec3(3, 4, 5);
      backend.release.complete();
      final output = await rendering as PresentedOutput;
      expect(output.surface, same(backend.surface));
      expect(output.epoch, 7);
      expect(output.frameId, 42);
      expect(output.stats.source!.sceneRevision, sceneRevision);
      expect(output.stats.source!.sceneRevision, isNot(scene.revision));
      expect(output.stats.source!.cameraRevision, cameraRevision);
      expect(output.stats.source!.cameraRevision, isNot(camera.revision));
      expect(output.stats.source!.cameraRuntimeId, camera.id);
      expect(output.stats.source!.logicalWidth, isNull);
      final withViewport = output.withStats(
        output.stats.withSource(
          output.stats.source!.withViewport(
            logicalWidth: 4,
            logicalHeight: 6,
            devicePixelRatio: 2,
          ),
        ),
      );
      expect(withViewport.stats.source!.devicePixelRatio, 2);
      expect(withViewport.stats.uploadedBytes, 19);
      expect(withViewport.stats.computeDispatches, 3);
      expect(withViewport.stats.residentBytes, isNull);
      expect(withViewport.stats.gpuTime, const Duration(microseconds: 17));
      expect(output.stats.source!.devicePixelRatio, isNull);
    },
  );
  test('legacy renderers do not acquire inferred source correlation', () async {
    final engine = await SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      rendererFactory: () async => TestRenderer([]),
    );
    addTearDown(engine.dispose);
    final output = await engine.renderFrame(
      elapsed: Duration.zero,
      width: 8,
      height: 8,
    );
    expect(output.stats.source, isNull);
  });
}

class _Surface implements SurfaceKey {}

class _DelayedBackend implements RenderBackend {
  final surface = _Surface();
  final started = Completer<void>(), release = Completer<void>();
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'test',
    features: {RenderFeature.sharedTexture},
    limits: DeviceLimits(maxTextureDimension2D: 4096, maxGeometryBytes: 1024),
  );
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    started.complete();
    await release.future;
    return PresentedOutput(
      surface: surface,
      epoch: 7,
      frameId: 42,
      stats: FrameStats(
        frameId: 42,
        surfaceEpoch: 7,
        physicalSize: submission.size,
        presentationPath: PresentationPath.sharedTexture,
        cpuBuildTime: Duration.zero,
        cpuSubmitTime: Duration.zero,
        drawCalls: 0,
        triangles: 0,
        readbackBytes: 0,
        uploadedBytes: 19,
        computeDispatches: 3,
        gpuTime: const Duration(microseconds: 17),
      ),
    );
  }

  @override
  Future<void> close() async {}
}
