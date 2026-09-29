import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shader_lab/physical.dart';
import 'effects_test.dart' show waitForFrame;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'physical glass and area lights present through native AA and resize',
    (tester) async {
      await tester.pumpWidget(const PhysicalLabApp());
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      final issues = <SceneIssue>[];
      final subscription = controller.issues.listen(issues.add);
      try {
        final first = await waitForFrame(
          tester,
          controller,
          (f) => f.drawCalls >= 20,
        );
        expect(first.readbackBytes, 0);
        // One glass mesh: capture has N-1 draws, main has N, HDR resolve has one.
        final temporalDraws = first.drawCalls + first.drawCalls ~/ 2 + 1;
        tester
            .widget<Slider>(find.byKey(const ValueKey('Roughness')))
            .onChanged!(.75);
        await tester.pump();
        await waitForFrame(tester, controller, (f) => f.uploadedBytes == 0);
        await tester.tap(find.widgetWithText(FilterChip, 'Area light'));
        await waitForFrame(
          tester,
          controller,
          (f) => f.drawCalls == first.drawCalls,
        );
        await tester.tap(find.widgetWithText(FilterChip, 'Temporal AA'));
        await waitForFrame(
          tester,
          controller,
          (f) => f.drawCalls == temporalDraws,
        );
        expect(controller.colorPipeline!.sampleCount, 1);
        await tester.tap(find.widgetWithText(FilterChip, 'Bloom'));
        await waitForFrame(
          tester,
          controller,
          (f) => f.drawCalls > temporalDraws,
        );
        for (final size in [const Size(320, 640), const Size(960, 720)]) {
          await tester.binding.setSurfaceSize(size);
          await tester.pump();
          await waitForFrame(tester, controller, (f) => f.readbackBytes == 0);
          expect(
            tester.getSize(find.byType(SceneView)).height,
            greaterThan(200),
          );
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.widgetWithText(FilterChip, '4× MSAA'));
        await waitForFrame(
          tester,
          controller,
          (f) => f.drawCalls < temporalDraws,
        );
        expect(controller.colorPipeline!.sampleCount, 4);
        expect(issues.where((i) => i.severity == IssueSeverity.error), isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await controller.whenDisposed;
        await subscription.cancel();
        await tester.binding.setSurfaceSize(null);
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
