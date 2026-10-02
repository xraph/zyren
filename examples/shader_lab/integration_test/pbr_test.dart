import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren/src/presentation/native_metal_presenter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shader_lab/pbr.dart';
import '../../../packages/zyren_native/test/support/pbr_checks.dart';
import '../../../packages/zyren_native/test/support/standard_maps_checks.dart';
import '../../../packages/zyren_native/test/support/hdr_checks.dart';
import '../../../packages/zyren_native/test/support/hdr_asset_checks.dart';
import '../../../packages/zyren_native/test/support/environment_checks.dart';
import '../../../packages/zyren_native/test/support/shadow_checks.dart';
import 'effects_test.dart' show waitForFrame;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('PBR reference pixels and native sphere-grid controls', (
    tester,
  ) async {
    final backend = Platform.isAndroid
        ? await NativeBackend.create()
        : await NativeMetalBackend.create();
    try {
      await verifyPbr(backend);
      await verifyStandardMaps(backend);
      await verifyHdr(backend);
      await verifyHdrAsset(backend);
      await verifyEnvironment(backend);
      await verifyShadows(backend);
    } finally {
      await backend.close();
    }
    await tester
        .pumpWidget(const PbrLabApp())
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TestFailure(
            'Flutter did not deliver a frame. The native window may be inactive.',
          ),
        );
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    try {
      final first = await waitForFrame(
        tester,
        controller,
        (frame) => frame.drawCalls == 14,
      );
      expect(first.readbackBytes, 0);
      final exposure = controller.colorPipeline!.exposure;
      await tester.drag(
        find.byKey(const ValueKey('Exposure')),
        const Offset(-40, 0),
      );
      final exposed = await waitForFrame(
        tester,
        controller,
        (f) => f.drawCalls == 14 && f.uploadedBytes == 0,
      );
      expect(exposed.readbackBytes, 0);
      expect(controller.colorPipeline!.exposure, lessThan(exposure));
      expect(first.presentationPath, isNot(PresentationPath.readback));
      final light = controller.scene.children
          .whereType<DirectionalLight>()
          .single;
      expect(light.shadow, isNotNull);
      await tester.tap(find.byKey(const ValueKey('Shadows')));
      await waitForFrame(
        tester,
        controller,
        (frame) => frame.uploadedBytes == 0,
      );
      expect(light.shadow, isNull);
      await tester.tap(find.byKey(const ValueKey('Shadows')));
      await waitForFrame(
        tester,
        controller,
        (frame) => frame.uploadedBytes == 0,
      );
      expect(light.shadow, isNotNull);
      final before = light.intensity;
      await tester.drag(
        find.byKey(const ValueKey('Light')),
        const Offset(-40, 0),
      );
      final edited = await waitForFrame(
        tester,
        controller,
        (frame) => frame.uploadedBytes == 0,
      );
      expect(light.intensity, lessThan(before));
      expect(edited.drawCalls, 14);
      final orientation = light.quaternion;
      await tester.drag(
        find.byKey(const ValueKey('Angle')),
        const Offset(60, 0),
      );
      await waitForFrame(tester, controller, (frame) => frame.drawCalls == 14);
      expect(light.quaternion, isNot(orientation));
      final hemisphere = controller.scene.children
          .whereType<HemisphereLight>()
          .single;
      final beforeAmbient = hemisphere.intensity;
      await tester.drag(
        find.byKey(const ValueKey('Ambient')),
        const Offset(40, 0),
      );
      await waitForFrame(tester, controller, (frame) => frame.drawCalls == 14);
      expect(hemisphere.intensity, greaterThan(beforeAmbient));
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(const ValueKey('Textures')));
        final toggled = await waitForFrame(
          tester,
          controller,
          (frame) => frame.drawCalls == 14,
        );
        expect(toggled.readbackBytes, 0);
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('LightingControls')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Environment').last);
      await tester.pumpAndSettle();
      for (final label in ['Sky', 'Rotation']) {
        await tester.drag(find.byKey(ValueKey(label)), const Offset(40, 0));
        final frame = await waitForFrame(
          tester,
          controller,
          (frame) => frame.drawCalls == 14 && frame.uploadedBytes == 0,
        );
        expect(frame.readbackBytes, 0);
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      await controller.whenDisposed;
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
