import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';

final class _View implements SceneCaptureView {
  int closes = 0;
  @override
  Future<void> close() async {
    closes++;
  }

  @override
  Future<void> clear() async {}
  @override
  void configureSceneUploadBudget(int bytes) {}
  @override
  Future<SceneCaptureReceipt> capture(
    FrameSubmission submission,
    GpuResource<Texture> target,
  ) => throw UnimplementedError();
}

final class _Backend implements CaptureBackend {
  final views = <_View>[];
  Completer<void>? gate;
  final entered = Completer<void>();
  @override
  final capabilities = DeviceCapabilities(
    name: 'capture fixture',
    features: {RenderFeature.sceneCapture},
    limits: DeviceLimits(maxTextureDimension2D: 64, maxGeometryBytes: 4096),
  );
  @override
  Future<SceneCaptureView> createCaptureView() async {
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    final view = _View();
    views.add(view);
    return view;
  }

  @override
  Future<FrameOutput> render(FrameSubmission submission) =>
      throw UnimplementedError();
  @override
  Future<void> close() async {
    expect(views.every((v) => v.closes == 1), isTrue);
  }
}

final class _CapturePlugin extends ScenePlugin {
  @override
  String get id => 'capture';
  late PluginContext context;
  late SceneCaptureView view;
  @override
  Future<void> attach(PluginContext context) async {
    this.context = context;
    view = await context.createCaptureView();
  }
}

void main() {
  test(
    'capture leases close exactly once on early retirement and detach',
    () async {
      final backend = _Backend(), plugin = _CapturePlugin();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [plugin],
      );
      await plugin.view.close();
      await plugin.view.close();
      expect(backend.views.single.closes, 1);
      await expectLater(plugin.view.clear(), throwsStateError);
      final second = await plugin.context.createCaptureView();
      await engine.dispose();
      await second.close();
      expect(backend.views.map((v) => v.closes), [1, 1]);
      await expectLater(plugin.context.createCaptureView(), throwsStateError);
    },
  );
  test(
    'cancelled capture creation closes a lease returned after cancellation',
    () async {
      final backend = _Backend()..gate = Completer<void>();
      final lifetime = AttachmentScope();
      final pending = SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [_CapturePlugin()],
        lifetime: lifetime,
      );
      final rejection = expectLater(pending, throwsA(isA<SceneException>()));
      await backend.entered.future;
      lifetime.close();
      backend.gate!.complete();
      await rejection;
      expect(backend.views.single.closes, 1);
    },
  );
}
