import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';
import 'support/fakes.dart';
import 'dart:typed_data';

void main() {
  test('staging source follows published scene and current camera', () async {
    final backend = SurfaceBackend();
    final scene = Scene();
    final camera = PerspectiveCamera();
    final engine = await SceneEngine.create(
      scene: scene,
      camera: camera,
      backendFactory: () async => backend,
    );
    Future<FrameOutput> draw() => engine.renderFrame(
      elapsed: Duration.zero,
      width: 16,
      height: 16,
      target: SurfaceTarget(backend.key, 0),
    );
    backend.admission = SceneAdmission(
      candidateReady: true,
      publishedRevision: 1,
      uploadBacklogBytes: 0,
      stagedBytes: 0,
      presentedIdentities: [],
    );
    final old = await draw();
    scene.background = const Color3(1, 0, 0);
    camera.position = const Vec3(1, 0, 5);
    backend.admission = SceneAdmission(
      candidateReady: false,
      publishedRevision: 1,
      uploadBacklogBytes: 100,
      stagedBytes: 100,
      presentedIdentities: [],
    );
    final staging = await draw();
    expect(
      staging.stats.source!.sceneRevision,
      old.stats.source!.sceneRevision,
    );
    expect(staging.stats.source!.cameraRevision, camera.revision);
    backend.admission = SceneAdmission(
      candidateReady: true,
      publishedRevision: 3,
      uploadBacklogBytes: 0,
      stagedBytes: 0,
      presentedIdentities: [],
    );
    final published = await draw();
    expect(published.stats.source!.sceneRevision, scene.revision);
    await engine.dispose();
  });
  test('legacy renderer alpha metadata survives the engine adapter', () async {
    final engine = await SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      rendererFactory: () async => _AlphaRenderer(),
    );
    final output =
        await engine.renderFrame(elapsed: Duration.zero, width: 1, height: 1)
            as ReadbackOutput;
    expect(output.image.alphaMode, AlphaMode.premultiplied);
    await engine.dispose();
  });
  test(
    'engine preserves surface receipts and gives plugins pixel-free stats',
    () async {
      final backend = SurfaceBackend();
      final plugin = StatsPlugin();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [plugin],
      );
      final result = await engine.renderFrame(
        elapsed: Duration.zero,
        width: 63,
        height: 47,
        target: SurfaceTarget(backend.key, 3),
      );
      expect(result, isA<PresentedOutput>());
      expect((result as PresentedOutput).surface, same(backend.key));
      expect(result.epoch, 3);
      expect(plugin.stats?.readbackBytes, 0);
      expect(plugin.stats?.presentationPath, PresentationPath.sharedTexture);
      await engine.dispose();
      expect(backend.closed, isTrue);
    },
  );
}

class _AlphaRenderer extends TestRenderer {
  _AlphaRenderer() : super([]);
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) async => RenderedFrame(
    Uint8List.fromList([64, 0, 0, 128]),
    1,
    1,
    alphaMode: AlphaMode.premultiplied,
  );
}

class TestSurfaceKey implements SurfaceKey {}

class StatsPlugin extends ScenePlugin {
  @override
  String get id => 'stats';
  FrameStats? stats;
  @override
  void afterRender(PluginContext context, FrameInfo info, FrameStats stats) {
    this.stats = stats;
  }
}

class SurfaceBackend implements RenderBackend {
  final key = TestSurfaceKey();
  bool closed = false;
  SceneAdmission? admission;
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'surface',
    features: {RenderFeature.sharedTexture},
    limits: DeviceLimits(maxTextureDimension2D: 4096, maxGeometryBytes: 1024),
  );
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    final target = submission.target as SurfaceTarget;
    return PresentedOutput(
      surface: target.surface,
      epoch: target.epoch,
      frameId: 7,
      stats: FrameStats(
        admission: admission,
        frameId: 7,
        surfaceEpoch: target.epoch,
        physicalSize: submission.size,
        presentationPath: PresentationPath.sharedTexture,
        cpuBuildTime: Duration.zero,
        cpuSubmitTime: Duration.zero,
        drawCalls: 0,
        triangles: 0,
        readbackBytes: 0,
        uploadedBytes: 0,
      ),
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
