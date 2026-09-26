import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';

void main() {
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
