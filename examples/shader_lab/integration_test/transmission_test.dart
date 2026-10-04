import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shader_lab/pbr.dart';
import 'effects_test.dart' show waitForFrame;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('transmission controls present at desktop and narrow sizes', (
    tester,
  ) async {
    await tester.pumpWidget(const PbrLabApp());
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    final issues = <SceneIssue>[];
    final subscription = controller.issues.listen(issues.add);
    try {
      await waitForFrame(tester, controller, (f) => f.readbackBytes == 0);
      await tester.tap(find.byKey(const ValueKey('LightingControls')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transmission').last);
      await tester.pump();
      final first = await waitForFrame(
        tester,
        controller,
        (f) => f.profile?.passes['transmission']?.executed == true,
      );
      expect(first.readbackBytes, 0);
      expect(first.profile!.passes['scene']!.drawCalls, 2);
      final info = await controller.ready;
      debugPrint(
        jsonEncode({
          'adapter': info.adapterName,
          'backend': info.backend,
          'presentation': info.presentationPath.name,
          'frame': first.profile!.toJson(),
        }),
      );
      for (final size in [const Size(1100, 700), const Size(320, 640)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pump();
        await waitForFrame(tester, controller, (f) => f.readbackBytes == 0);
        expect(tester.getSize(find.byType(SceneView)).height, greaterThan(250));
        expect(tester.takeException(), isNull);
        for (final rough in [0.0, .7]) {
          tester.widget<Slider>(find.byKey(const ValueKey('Rough'))).onChanged!(
            rough,
          );
          tester
              .widget<Slider>(find.byKey(const ValueKey('Dispersion')))
              .onChanged!(2);
          await tester.pump();
          final frame = await waitForFrame(
            tester,
            controller,
            (f) =>
                f.profile?.passes['scene']?.drawCalls == 2 &&
                f.uploadedBytes == 0,
          );
          expect(frame.readbackBytes, 0);
          debugPrint(
            'transmission ${size.width}x${size.height} rough=$rough draws=${frame.drawCalls} scene=${frame.profile!.passes['scene']!.drawCalls} capture=${frame.profile!.passes['transmission']!.drawCalls}',
          );
        }
      }
      await tester.tap(find.byKey(const ValueKey('GlassMSAA')));
      await tester.pump();
      final multisample = await waitForFrame(
        tester,
        controller,
        (f) => f.profile?.passes['scene']?.drawCalls == 14,
      );
      expect(multisample.readbackBytes, 0);
      expect(controller.colorPipeline!.sampleCount, 4);
      expect(issues, isEmpty);
      debugPrint(
        'MSAA fallback draws=${multisample.drawCalls} scene=${multisample.profile!.passes['scene']!.drawCalls}',
      );
    } finally {
      await subscription.cancel();
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    }
  });
}
