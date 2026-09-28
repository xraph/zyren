import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shader_lab/pbr.dart';
import 'effects_test.dart' show waitForFrame;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native MSAA and bloom survive toggles and viewport resize', (
    tester,
  ) async {
    await tester
        .pumpWidget(const PbrLabApp(postProcessing: true))
        .timeout(const Duration(seconds: 20));
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    final issues = controller.issues.listen(
      (issue) => debugPrint(issue.toString()),
    );
    try {
      final initial = await waitForFrame(
        tester,
        controller,
        (f) => f.drawCalls > 13,
      );
      expect(initial.readbackBytes, 0);
      expect(controller.colorPipeline!.sampleCount, 4);
      await tester.tap(find.widgetWithText(FilterChip, 'Spatial AA'));
      await tester.pump();
      expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Spatial AA')).selected, isTrue);
      await waitForFrame(
        tester,
        controller,
        (f) => f.drawCalls == initial.drawCalls + 1 && f.readbackBytes == 0,
      );
      await tester.tap(find.widgetWithText(FilterChip, 'Bloom'));
      await waitForFrame(
        tester,
        controller,
        (f) => f.drawCalls == initial.drawCalls - 3,
      );
      await tester.tap(find.widgetWithText(FilterChip, '4× MSAA'));
      await waitForFrame(tester, controller, (f) => f.uploadedBytes == 0);
      expect(controller.colorPipeline!.sampleCount, 1);
      for (final size in [const Size(320, 640), const Size(960, 720)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pump();
        await waitForFrame(tester, controller, (f) => f.readbackBytes == 0);
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(SceneView)).height, greaterThan(200));
      }
      await tester.tap(find.widgetWithText(FilterChip, 'Bloom'));
      await tester.tap(find.widgetWithText(FilterChip, '4× MSAA'));
      await waitForFrame(
        tester,
        controller,
        (f) => f.drawCalls == initial.drawCalls + 1,
      );
      expect(controller.colorPipeline!.sampleCount, 4);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await controller.whenDisposed;
      await issues.cancel();
      await tester.binding.setSurfaceSize(null);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
