import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shader_lab/culling.dart';
import 'effects_test.dart' show waitForFrame;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native culling switches draws while retaining shared resources',
    (tester) async {
      await tester.pumpWidget(const CullingLabApp());
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      try {
        final first = await waitForFrame(
          tester,
          controller,
          (frame) => frame.drawCalls > 0 && frame.drawCalls < 61,
        );
        expect(first.readbackBytes, 0);
        expect(first.uploadedBytes, 1104);
        await tester.tap(find.byKey(const ValueKey('Culling enabled')));
        final full = await waitForFrame(
          tester,
          controller,
          (frame) => frame.drawCalls == 61,
        );
        expect(full.uploadedBytes, 0);
        expect(full.readbackBytes, 0);
        await tester.tap(find.byKey(const ValueKey('Culling enabled')));
        await waitForFrame(tester, controller, (frame) => frame.drawCalls < 61);
        tester
            .widget<Slider>(find.byKey(const ValueKey('Camera pan')))
            .onChanged!(20);
        final moved = await waitForFrame(
          tester,
          controller,
          (frame) => frame.uploadedBytes == 0,
        );
        expect(controller.camera.position.x, 20);
        expect(moved.drawCalls, inInclusiveRange(1, 20));
        expect(moved.readbackBytes, 0);
        await tester.tap(find.byKey(const ValueKey('Culling projection')));
        await waitForFrame(
          tester,
          controller,
          (frame) => frame.readbackBytes == 0,
        );
        expect(controller.camera, isA<OrthographicCamera>());
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await controller.whenDisposed;
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
