import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_gpu3d/src/presentation/native_metal_presenter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:gpu3d/rendering.dart' show PresentationPath;
import 'package:shader_lab/pbr.dart';
import '../../../packages/gpu3d_native/test/support/pbr_checks.dart';
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
    } finally {
      await backend.close();
    }
    await tester.pumpWidget(const PbrLabApp());
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    try {
      final first = await waitForFrame(
        tester,
        controller,
        (frame) => frame.drawCalls == 12,
      );
      expect(first.readbackBytes, 0);
      expect(first.presentationPath, isNot(PresentationPath.readback));
      final light = controller.scene.children
          .whereType<DirectionalLight>()
          .single;
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
      expect(edited.drawCalls, 12);
      final orientation = light.quaternion;
      await tester.drag(
        find.byKey(const ValueKey('Angle')),
        const Offset(60, 0),
      );
      await waitForFrame(tester, controller, (frame) => frame.drawCalls == 12);
      expect(light.quaternion, isNot(orientation));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await controller.whenDisposed;
    }
  });
}
