import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'controller_test.dart' show frames, host;

void main() {
  testWidgets(
    'shared policy presents a texture without calling the image presenter',
    (tester) async {
      final backend = SurfaceBackend();
      final factory = SurfaceFactory(backend.key);
      final controller = SceneController(
        runtime: SceneRuntime(
          backendFactory: () async => backend,
          surfacePresenterFactory: factory,
          presenterFactory: () => throw StateError('readback was selected'),
        ),
      );
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      expect(find.byType(Texture), findsOneWidget);
      expect((await controller.firstFrame).readbackBytes, 0);
      expect(
        (await controller.ready).presentationPath,
        PresentationPath.sharedTexture,
      );
      expect(backend.targets, everyElement(isA<SurfaceTarget>()));
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
      expect(factory.closed, 1);
      expect(backend.closed, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class TestKey implements SurfaceKey {}

class SurfaceBackend implements RenderBackend {
  final key = TestKey();
  final targets = <OutputTarget>[];
  int closed = 0;
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'surface',
    features: {RenderFeature.sharedTexture},
    limits: DeviceLimits(maxTextureDimension2D: 64, maxGeometryBytes: 1024),
  );
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    targets.add(submission.target);
    final target = submission.target as SurfaceTarget;
    return PresentedOutput(
      surface: target.surface,
      epoch: target.epoch,
      frameId: 1,
      stats: FrameStats(
        frameId: 1,
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
    closed++;
  }
}

class SurfaceFactory implements SurfacePresenterFactory {
  final TestKey key;
  int closed = 0;
  SurfaceFactory(this.key);
  @override
  bool supports(RenderBackend backend) => backend is SurfaceBackend;
  @override
  OutputPresenter create(RenderBackend backend) => SurfacePresenter(this);
}

class SurfacePresenter implements OutputPresenter {
  final SurfaceFactory owner;
  SurfacePresenter(this.owner);
  @override
  Future<OutputTarget> prepare(PhysicalSize size) async =>
      SurfaceTarget(owner.key, 1);
  @override
  Future<PresentedFrame> present(FrameOutput output) async {
    if (output is! PresentedOutput) {
      throw StateError('image returned for surface');
    }
    return TextureFrame();
  }

  @override
  Future<void> setSuspended(bool value) async {}
  @override
  Future<void> dispose() async {
    owner.closed++;
  }
}

class TextureFrame implements PresentedFrame {
  @override
  Widget build(BuildContext context) => const Texture(textureId: 9);
  @override
  void dispose() {}
}
