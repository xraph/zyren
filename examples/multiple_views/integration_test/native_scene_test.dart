import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multiple_views/main.dart';
import 'package:multiple_views/textured_scene_demo.dart';

class Probe extends ScenePlugin {
  @override
  String get id => 'native-view-probe';
  final frames = <FrameStats>[];
  int before = 0, detached = 0;
  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    before++;
  }

  @override
  void afterRender(PluginContext context, FrameInfo info, FrameStats stats) {
    frames.add(stats);
  }

  @override
  void detach(PluginContext context) {
    detached++;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final android = Platform.isAndroid;
  final runtime = android
      ? const SceneRuntime.nativeAndroid()
      : const SceneRuntime.nativeMetal();
  final path = android
      ? PresentationPath.sharedTexture
      : PresentationPath.nativeView;
  final ownership = android ? 'surfaces' : 'heldDrawables';
  final channel = MethodChannel(
    android ? 'gpu3d/android-surfaces' : 'gpu3d/scene-views',
  );
  Future<Map<Object?, Object?>> stats() async =>
      (await channel.invokeMapMethod<Object?, Object?>('diagnostics'))!;
  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      if (ready()) return;
    }
    fail('Native SceneView did not reach expected state. ${await stats()}');
  }

  testWidgets(
    'SceneView uses native GPU with core updates, hooks, input and remount',
    (tester) async {
      final controller = SceneController(runtime: runtime);
      final mesh = controller.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      final probe = controller.use(Probe());
      final update = controller.onUpdate(
        (time) => mesh.rotateY(time.deltaSeconds),
      );
      var pointers = 0;
      Widget host() => MaterialApp(
        home: Center(
          child: SizedBox(
            width: 127,
            height: 93,
            child: SceneView(
              controller: controller,
              onPointer: (_) => pointers++,
            ),
          ),
        ),
      );
      await tester.pumpWidget(host());
      await until(
        tester,
        () =>
            probe.frames.length >= 30 || controller.status.value is SceneFailed,
      );
      expect(controller.status.value, isA<SceneReady>());
      expect((await controller.ready).presentationPath, path);
      expect(probe.frames.map((f) => f.presentationPath), everyElement(path));
      expect(probe.frames.map((f) => f.readbackBytes), everyElement(0));
      expect(probe.frames.first.uploadedBytes, greaterThan(0));
      expect(probe.frames.last.uploadedBytes, 0);
      expect(probe.before, greaterThanOrEqualTo(probe.frames.length));
      expect(find.byType(RawImage), findsNothing);
      expect(find.byType(Texture), android ? findsOneWidget : findsNothing);
      await tester.tap(find.byType(SceneView));
      await tester.pump();
      expect(pointers, greaterThan(0));
      update.dispose();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      final idle = (await stats())['presented'];
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect((await stats())['presented'], idle);
      final beforeEdit = probe.frames.length;
      mesh.material = UnlitMaterial(color: const Color3(1, 0, 0));
      await until(tester, () => probe.frames.length > beforeEdit);
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(controller.isDisposed, isFalse);
      expect((await stats())['renderers'], 1);
      expect((await stats())[ownership], 0);
      final detachedCount = probe.frames.length;
      await tester.pumpWidget(host());
      await until(
        tester,
        () =>
            probe.frames.length > detachedCount ||
            controller.status.value is SceneFailed,
      );
      expect(controller.status.value, isA<SceneReady>());
      expect(probe.frames.last.uploadedBytes, 0);
      controller.dispose();
      await tester.pumpWidget(const SizedBox());
      await until(tester, () => probe.detached == 1);
      await controller.whenDisposed;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      final closed = await stats();
      expect(closed['sessions'], 0);
      expect(closed['renderers'], 0);
      expect(closed[ownership], 0);
      expect(closed['readbackBytes'], 0);
      debugPrint('Integrated native SceneView: $closed');
    },
  );
  testWidgets('two native views keep cameras and teardown independent', (
    tester,
  ) async {
    await tester.pumpWidget(
      MultipleViewsApp(
        runtime: runtime,
        presentation: PresentationPolicy.requireNative,
      ),
    );
    final views = tester.widgetList<SceneView>(find.byType(SceneView)).toList();
    final left = views.first.controller!, right = views.last.controller!;
    final leftFrames = <FrameStats>[], rightFrames = <FrameStats>[];
    final leftSub = left.frameStats.listen(leftFrames.add);
    final rightSub = right.frameStats.listen(rightFrames.add);
    await until(tester, () => leftFrames.isNotEmpty && rightFrames.isNotEmpty);
    expect(left.scene, same(right.scene));
    final originalRight = right.camera.position;
    final originalLeft = left.camera.position;
    final originalFrames = rightFrames.length;
    // Public diagnostics are sampled every 200 ms.
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Move left camera'));
    expect(left.camera.position, originalLeft + const Vec3(.25, 0, 0));
    await until(tester, () => leftFrames.length > 1);
    expect(right.camera.position, originalRight);
    expect(rightFrames.length, originalFrames);
    await tester.tap(find.text('Turn mesh'));
    await until(tester, () => rightFrames.length > originalFrames);
    await tester.tap(find.text('Close left view'));
    await tester.pump();
    await left.whenDisposed;
    expect((await stats())['renderers'], 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 25));
    await right.whenDisposed;
    await leftSub.cancel();
    await rightSub.cancel();
    expect((await stats())['renderers'], 0);
  });

  testWidgets('native SceneView follows physical size and visibility', (
    tester,
  ) async {
    final controller = SceneController(runtime: runtime);
    final mesh = controller.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    final frames = <FrameStats>[];
    final subscription = controller.frameStats.listen(frames.add);
    var enabled = true, small = false;
    Widget host() => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 2),
        child: TickerMode(
          enabled: enabled,
          child: Center(
            child: SizedBox(
              width: small ? 83 : 127,
              height: small ? 61 : 93,
              child: SceneView(
                controller: controller,
                resolutionScale: small ? .5 : 1,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host());
    await until(tester, () => frames.isNotEmpty);
    expect(frames.last.physicalSize.width, 254);
    expect(frames.last.physicalSize.height, 186);
    await tester.pump(const Duration(milliseconds: 250));
    small = true;
    await tester.pumpWidget(host());
    await until(tester, () => frames.last.physicalSize.width == 83);
    expect(frames.last.physicalSize.height, 61);
    enabled = false;
    await tester.pumpWidget(host());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    final paused = frames.length;
    mesh.rotateY(.2);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(frames.length, paused);
    // Android retains the registered texture while its viewport is suspended.
    expect((await stats())[ownership], android ? 1 : 0);
    enabled = true;
    await tester.pumpWidget(host());
    await until(tester, () => frames.length > paused);
    controller.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 25));
    await controller.whenDisposed;
    await subscription.cancel();
    expect((await stats())['renderers'], 0);
  });

  testWidgets('100 managed native SceneViews return ownership to baseline', (
    tester,
  ) async {
    for (var cycle = 0; cycle < 100; cycle++) {
      late SceneController controller;
      var ready = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 65,
              height: 49,
              child: SceneView.builder(
                key: ValueKey(cycle),
                runtime: runtime,
                onCreate: (value) {
                  controller = value;
                  value.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
                  value.firstFrame.then((_) => ready = true);
                },
              ),
            ),
          ),
        ),
      );
      await until(
        tester,
        () => ready || controller.status.value is SceneFailed,
      );
      expect(
        controller.status.value,
        isA<SceneReady>(),
        reason: 'cycle $cycle',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 25));
      await controller.whenDisposed;
      final closed = await stats();
      expect(closed['sessions'], 0, reason: 'cycle $cycle');
      expect(closed['renderers'], 0, reason: 'cycle $cycle');
      expect(closed['retiring'], 0, reason: 'cycle $cycle');
      expect(closed[ownership], 0, reason: 'cycle $cycle');
      expect(closed['readbackBytes'], 0, reason: 'cycle $cycle');
    }
    debugPrint('100 managed native SceneView cycles: ${await stats()}');
  });

  testWidgets(
    'textured native SceneView updates samplers without image upload',
    (tester) async {
      await tester.pumpWidget(TexturedSceneApp(runtime: runtime));
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      final frames = <FrameStats>[];
      final subscription = controller.frameStats.listen(frames.add);
      await until(
        tester,
        () => frames.isNotEmpty || controller.status.value is SceneFailed,
      );
      expect(controller.status.value, isA<SceneReady>());
      expect(
        (await controller.ready).capabilities.supports(
          RenderFeature.colorTextures,
        ),
        isTrue,
      );
      expect(frames.first.uploadedBytes, 200);
      expect(frames.first.readbackBytes, 0);
      expect(frames.first.presentationPath, path);
      // Public frame statistics are sampled at most once every 200 ms.
      await tester.pump(const Duration(milliseconds: 250));
      var count = frames.length;
      await tester.tap(find.text('Linear'));
      await until(tester, () => frames.length > count);
      expect(frames.last.uploadedBytes, 0);
      await tester.pump(const Duration(milliseconds: 250));
      count = frames.length;
      await tester.tap(find.text('Clamp'));
      await until(tester, () => frames.length > count);
      expect(frames.last.uploadedBytes, 0);
      expect(find.byType(RawImage), findsNothing);
      expect(frames.map((frame) => frame.readbackBytes), everyElement(0));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 25));
      await controller.whenDisposed;
      await subscription.cancel();
      final closed = await stats();
      expect(closed['sessions'], 0);
      expect(closed['renderers'], 0);
      expect(closed[ownership], 0);
    },
  );

  testWidgets(
    'explicit capture returns real RGBA pixels and measured readback',
    (tester) async {
      final backend = await const SceneRuntime.nativeMetal().backendFactory();
      final output =
          await backend.render(
                FrameSubmission.capture(
                  scene: Scene()..background = const Color3(1, 0, 0),
                  camera: PerspectiveCamera(),
                  size: PhysicalSize(63, 47),
                ),
              )
              as ReadbackOutput;
      expect(output.image.pixels.sublist(0, 4), [255, 0, 0, 255]);
      expect(output.stats.presentationPath, PresentationPath.readback);
      expect(output.stats.readbackBytes, 63 * 47 * 4);
      await backend.close();
      final closed = await stats();
      expect(closed['sessions'], 0);
      expect(closed['renderers'], 0);
      expect(closed[ownership], 0);
      expect(closed['readbackBytes'], 63 * 47 * 4);
      debugPrint('Explicit native capture: $closed');
    },
    skip: Platform.isAndroid,
  );
}
