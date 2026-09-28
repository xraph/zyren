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
      final frames = <FrameStats>[];
      final subscription = controller.frameStats.listen(frames.add);
      Future<void> advance(int count) async {
        for (var i = 0; i < count; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

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
        await tester.tap(find.byKey(const ValueKey('Frame all')));
        final fitted = await waitForFrame(
          tester,
          controller,
          (frame) => frame.drawCalls == 61,
        );
        expect(fitted.uploadedBytes, 0);
        expect(fitted.readbackBytes, 0);
        await tester.tapAt(tester.getCenter(find.byType(SceneView)));
        await tester.pumpAndSettle();
        expect(find.textContaining('Box 30 selected'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('Frame selection')));
        final focused = await waitForFrame(
          tester,
          controller,
          (frame) => frame.drawCalls > 0 && frame.drawCalls < 5,
        );
        expect(focused.uploadedBytes, 0);
        expect(focused.readbackBytes, 0);
        await tester.tap(find.byKey(const ValueKey('Culling projection')));
        await waitForFrame(
          tester,
          controller,
          (frame) => frame.drawCalls > 0 && frame.drawCalls < 5,
        );
        expect(controller.camera, isA<PerspectiveCamera>());
        final beforeOrbit = controller.camera.position;
        await tester.dragFrom(
          tester.getCenter(find.byType(SceneView)),
          const Offset(70, 30),
        );
        await advance(100);
        expect(controller.camera.position, isNot(beforeOrbit));
        expect(frames.last.uploadedBytes, 0);
        expect(frames.last.readbackBytes, 0);
        final settled = frames.length;
        await advance(20);
        expect(
          frames.length,
          settled,
          reason: 'Orbit releases demand after damping.',
        );
        await tester.tap(find.byKey(const ValueKey('Reset orbit')));
        await waitForFrame(
          tester,
          controller,
          (frame) => frame.readbackBytes == 0,
        );
        expect(controller.camera.position, beforeOrbit);
        expect(tester.takeException(), isNull);
      } finally {
        await subscription.cancel();
        await tester.pumpWidget(const SizedBox());
        await controller.whenDisposed;
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
