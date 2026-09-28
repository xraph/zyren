import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_gpu3d/src/presentation/native_metal_presenter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpu3d/rendering.dart' show PresentationPath;
import 'package:integration_test/integration_test.dart';
import 'package:shader_lab/main.dart';
import 'package:shader_lab_effects/shader_lab_effects.dart';
import '../effects_plugin/test/support/native_checks.dart';
import '../../../packages/gpu3d_native/test/support/mesh_shader_checks.dart';
import '../../../packages/gpu3d_native/test/support/graph_phase_checks.dart';

Future<FrameStats> waitForFrame(
  WidgetTester tester,
  SceneController controller,
  bool Function(FrameStats) accept,
) async {
  FrameStats? result;
  final observed = <int>[];
  final sub = controller.frameStats.listen((frame) {
    observed.add(frame.drawCalls);
    if (accept(frame)) result = frame;
  });
  try {
    controller.invalidate();
    for (var i = 0; i < 200 && result == null; i++) {
      // Telemetry is throttled to 5 Hz, while this view renders on demand.
      controller.invalidate();
      await tester.pump(const Duration(milliseconds: 16));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      result,
      isNotNull,
      reason:
          'Native draws: $observed. Controller: ${controller.status.value}.',
    );
    return result!;
  } finally {
    await sub.cancel();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native effects pixels and Flutter surface controls', (
    tester,
  ) async {
    final NativeGpuBackend backend = Platform.isAndroid
        ? await NativeBackend.create()
        : await NativeMetalBackend.create();
    try {
      await verifyEffects(backend);
      await verifySharedEffects(backend);
      await verifyMeshShaders(backend);
      await verifyMeshAttachmentAlias(backend);
      await verifyGraphPhases(backend);
    } finally {
      await backend.close();
    }
    final prepared = SceneController(
      runtime: Platform.isAndroid
          ? const SceneRuntime.nativeAndroid()
          : const SceneRuntime.nativeMetal(),
    );
    prepared.use(PreparedMaterialFixture());
    prepared.use(EffectsPlugin(options: EffectsOptions(vignette: 0)));
    try {
      await tester.pumpWidget(
        MaterialApp(home: SceneView(controller: prepared)),
      );
      final first = await waitForFrame(
        tester,
        prepared,
        (frame) => frame.computeDispatches == 1,
      );
      expect(first.drawCalls, 5);
      expect(first.readbackBytes, 0);
      expect(first.presentationPath, isNot(PresentationPath.readback));
      await tester.pumpWidget(
        MaterialApp(home: SceneView(controller: prepared, resolutionScale: .5)),
      );
      final resized = await waitForFrame(
        tester,
        prepared,
        (frame) => frame.physicalSize.width < first.physicalSize.width,
      );
      expect(resized.computeDispatches, 1);
      expect(resized.readbackBytes, 0);
    } finally {
      await tester.pumpWidget(const SizedBox());
      prepared.dispose();
      await prepared.whenDisposed;
    }
    await tester.pumpWidget(
      ShaderLabApp(
        runtime: Platform.isAndroid
            ? const SceneRuntime.nativeAndroid()
            : const SceneRuntime.nativeMetal(),
      ),
    );
    await tester.pump();
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    try {
      final first = await waitForFrame(
        tester,
        controller,
        (frame) => frame.drawCalls == 6,
      );
      expect(first.readbackBytes, 0);
      expect(
        (controller.scene.children[1] as Mesh).material,
        isA<ShaderMaterial>(),
      );
      expect(first.presentationPath, isNot(PresentationPath.readback));
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      final bypass = await waitForFrame(
        tester,
        controller,
        (frame) => frame.drawCalls == 3,
      );
      expect(bypass.readbackBytes, 0);
      await tester.tap(find.byType(Switch));
      await waitForFrame(tester, controller, (frame) => frame.drawCalls == 6);
      await tester.drag(
        find.byKey(const ValueKey('Saturation')),
        const Offset(-35, 0),
      );
      await waitForFrame(tester, controller, (frame) => frame.drawCalls == 6);
      final position = controller.camera.position;
      await tester.drag(
        find.byKey(const ValueKey('Stripes')),
        const Offset(30, 0),
      );
      await waitForFrame(tester, controller, (frame) => frame.drawCalls == 6);
      await tester.drag(find.byType(SceneView), const Offset(30, 15));
      await waitForFrame(tester, controller, (frame) => frame.drawCalls == 6);
      expect(controller.camera.position, isNot(position));
      await tester.tap(find.byKey(const ValueKey('resolution')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('50%').last);
      final resized = await waitForFrame(
        tester,
        controller,
        (frame) => frame.physicalSize.width < first.physicalSize.width,
      );
      expect(resized.readbackBytes, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await controller.whenDisposed;
    }
    final diagnostics = (await MethodChannel(
      Platform.isAndroid ? 'gpu3d/android-surfaces' : 'gpu3d/scene-views',
    ).invokeMapMethod<Object?, Object?>('diagnostics'))!;
    expect(diagnostics['sessions'], 0);
    expect(diagnostics['renderers'], 0);
    expect(diagnostics[Platform.isAndroid ? 'surfaces' : 'heldDrawables'], 0);
  });
}
