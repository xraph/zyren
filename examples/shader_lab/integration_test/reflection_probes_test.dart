import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shader_lab/pbr.dart';
import 'effects_test.dart' show waitForFrame;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native presenter captures and updates two local probes', (
    tester,
  ) async {
    await tester.pumpWidget(const PbrLabApp());
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    await waitForFrame(tester, controller, (f) => f.readbackBytes == 0);
    await tester.tap(find.byKey(const ValueKey('LightingControls')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local probes').last);
    await tester.pumpAndSettle();
    for (final (key, count) in [
      ('ProbeLeft', 1),
      ('ProbeRight', 2),
      ('ProbeLeft', 2),
    ]) {
      await tester.tap(find.byKey(ValueKey(key)));
      final frame = await waitForFrame(
        tester,
        controller,
        (f) =>
            controller.scene.reflectionProbes?.count == count &&
            !(controller.scene.reflectionProbes?.pending ?? true),
      );
      expect(frame.readbackBytes, 0);
      expect(controller.scene.reflectionProbes!.lastError, isNull);
      expect(controller.scene.reflectionProbes!.lastCapture!.readbackBytes, 0);
    }
    expect(controller.scene.reflectionProbes!.revision(0), 3);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
