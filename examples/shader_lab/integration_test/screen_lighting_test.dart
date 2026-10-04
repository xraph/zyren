import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shader_lab/pbr.dart';
import 'effects_test.dart' show waitForFrame;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'screen lighting presents with current source and compact controls',
    (tester) async {
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
        await tester.tap(find.text('Screen lighting').last);
        await tester.pumpAndSettle();
        for (final key in ['ScreenAO', 'ScreenSSR']) {
          await tester.tap(find.byKey(ValueKey(key)));
          await tester.pump();
        }
        final enabled = await waitForFrame(
          tester,
          controller,
          (f) =>
              f.profile?.screenLightingAoSamples == 12 &&
              f.profile?.screenLightingReflectionSteps == 32,
        );
        expect(enabled.readbackBytes, 0);
        expect(
          enabled.profile!.passes['screenLightingSource']!.executed,
          isTrue,
        );
        expect(enabled.profile!.screenLightingBytes, greaterThan(0));
        debugPrint(jsonEncode({'screenLighting': enabled.profile!.toJson()}));
        for (final size in [const Size(1100, 700), const Size(320, 640)]) {
          await tester.binding.setSurfaceSize(size);
          await tester.pump();
          tester
              .widget<DropdownButton<ScreenSpaceQuality>>(
                find.byKey(const ValueKey('ScreenQuality')),
              )
              .onChanged!(ScreenSpaceQuality.high);
          await tester.pump();
          final frame = await waitForFrame(
            tester,
            controller,
            (f) =>
                f.profile?.screenLightingReflectionSteps == 64 &&
                f.profile?.passes['screenLightingSource']?.executed == true,
          );
          expect(frame.readbackBytes, 0);
          expect(tester.takeException(), isNull);
          expect(
            tester.getSize(find.byType(SceneView)).height,
            greaterThan(250),
          );
          debugPrint(
            'screen lighting ${size.width}x${size.height}: source=${frame.profile!.passes['screenLightingSource']!.drawCalls}, main=${frame.profile!.passes['scene']!.drawCalls}, sharedBytes=${frame.profile!.screenLightingBytes}',
          );
        }
        await tester.tap(find.byKey(const ValueKey('GlassMSAA')));
        await tester.pump();
        final msaa = await waitForFrame(
          tester,
          controller,
          (f) => f.profile?.passes['screenLightingSource']?.executed == true,
        );
        expect(controller.colorPipeline!.sampleCount, 4);
        expect(msaa.readbackBytes, 0);
        expect(issues, isEmpty);
        for (final key in ['ScreenAO', 'ScreenSSR']) {
          await tester.tap(find.byKey(ValueKey(key)));
          await tester.pump();
        }
        final disabled = await waitForFrame(
          tester,
          controller,
          (f) => f.profile?.screenLightingBytes == 0,
        );
        expect(
          disabled.profile!.passes['screenLightingSource']!.executed,
          isFalse,
        );
      } finally {
        await subscription.cancel();
        await tester.pumpWidget(const SizedBox());
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}
