import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'controller_test.dart' show frames, host;
import 'shared_output_test.dart';

void main() {
  testWidgets('native view mounts before the first render and stays mounted', (
    tester,
  ) async {
    final backend = NativeViewFake();
    final factory = HostedFactory();
    final controller = SceneController(
      runtime: SceneRuntime(
        backendFactory: () async => backend,
        nativeViewPresenterFactory: factory,
      ),
    );
    await tester.pumpWidget(host(SceneView(controller: controller)));
    await frames(tester);
    expect(find.byKey(const ValueKey('native-host')), findsOneWidget);
    expect(
      (await controller.ready).presentationPath,
      PresentationPath.nativeView,
    );
    expect(backend.targets, isNotEmpty);
    expect(factory.presenter.mounts, 1);
    controller.invalidate();
    await frames(tester);
    expect(factory.presenter.mounts, 1);
    controller.dispose();
    await frames(tester);
    await controller.whenDisposed;
    expect(factory.presenter.closed, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'removal cancels a pending native attachment before waiting for a frame',
    (tester) async {
      final backend = NativeViewFake();
      final factory = HostedFactory()..attach = false;
      final controller = SceneController(
        runtime: SceneRuntime(
          backendFactory: () async => backend,
          nativeViewPresenterFactory: factory,
        ),
      );
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      expect(factory.presenter.mounts, 1);
      expect(backend.targets, isEmpty);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
      expect(factory.presenter.closed, 1);
      expect(backend.closed, 1);
    },
  );

  testWidgets('strict shared texture policy does not select a native view', (
    tester,
  ) async {
    final backend = NativeViewFake();
    final controller = SceneController(
      options: const EngineOptions(
        presentation: PresentationPolicy.requireSharedTexture,
      ),
      runtime: SceneRuntime(
        backendFactory: () async => backend,
        nativeViewPresenterFactory: HostedFactory(),
      ),
    );
    await tester.pumpWidget(host(SceneView(controller: controller)));
    await frames(tester);
    expect(controller.status.value, isA<SceneFailed>());
    expect(backend.closed, 1);
    controller.dispose();
    await frames(tester);
    await controller.whenDisposed;
    await tester.pumpWidget(const SizedBox());
  });
}

class NativeViewFake extends SurfaceBackend {
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'native-view',
    features: {RenderFeature.nativeView},
    limits: DeviceLimits(maxTextureDimension2D: 64, maxGeometryBytes: 1024),
  );
}

class HostedFactory implements SurfacePresenterFactory {
  bool attach = true;
  late HostedPresenter presenter;
  @override
  bool supports(RenderBackend backend) => backend is NativeViewFake;
  @override
  OutputPresenter create(RenderBackend backend) =>
      presenter = HostedPresenter((backend as NativeViewFake).key, attach);
}

class HostedPresenter implements HostedOutputPresenter {
  final TestKey key;
  final bool attach;
  final ready = Completer<void>();
  int mounts = 0, closed = 0;
  late final Widget widget = _Host(this);
  HostedPresenter(this.key, this.attach);
  @override
  Widget build(BuildContext context) => widget;
  @override
  void cancelPending() {
    if (!ready.isCompleted) {
      ready.completeError(StateError('attachment cancelled'));
    }
  }

  @override
  Future<OutputTarget> prepare(PhysicalSize size) async {
    await ready.future;
    return SurfaceTarget(key, 1);
  }

  @override
  Future<PresentedFrame> present(FrameOutput output) async => TextureFrame();
  @override
  Future<void> setSuspended(bool value) async {}
  @override
  Future<void> dispose() async {
    closed++;
  }
}

class _Host extends StatefulWidget {
  final HostedPresenter owner;
  const _Host(this.owner) : super(key: const ValueKey('native-host'));
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  void initState() {
    super.initState();
    widget.owner.mounts++;
    if (widget.owner.attach) widget.owner.ready.complete();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
