import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/atmosphere_lab.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'atmosphere presents day, dusk, night and orbit with compact controls and no readbacks',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      await tester.pumpWidget(const AtmosphereLabApp());
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      var frames = 0;
      final listener = controller.frameStats.listen((stats) {
        expectSync(stats.readbackBytes, 0);
        frames++;
      });
      Future<void> waitFrame(int previous) async {
        for (var i = 0; i < 1200; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (controller.status.value case SceneFailed(:final issue)) {
            fail('$issue');
          }
          if (frames > previous) return;
          if (i % 20 == 0) controller.invalidate();
        }
        fail('Atmosphere did not present a new frame.');
      }

      try {
        await waitFrame(0);
        for (final label in ['Dusk', 'Night', 'Day', 'Orbit', 'Horizon']) {
          final before = frames;
          await tester.tap(find.text(label));
          await waitFrame(before);
        }
        final before = frames;
        await tester.tap(find.byType(Switch));
        await waitFrame(before);
        for (final width in [320.0, 390.0, 1000.0]) {
          final before = frames;
          await tester.binding.setSurfaceSize(Size(width, 700));
          await waitFrame(before);
          expect(tester.takeException(), isNull);
          expect(
            tester.getSize(find.byType(SceneView)).height,
            greaterThan(480),
          );
          expect(find.text('Atmosphere'), findsOneWidget);
        }
        final beforeDrag = frames;
        await tester.drag(find.byType(SceneView), const Offset(45, 20));
        await waitFrame(beforeDrag);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await controller.whenDisposed;
        final channel = MethodChannel(
          defaultTargetPlatform == TargetPlatform.android
              ? 'zyren/android-surfaces'
              : 'zyren/scene-views',
        );
        final counts = (await channel.invokeMapMethod<Object?, Object?>(
          'diagnostics',
        ))!;
        for (final key in ['sessions', 'renderers', 'retiring']) {
          expect(counts[key], 0);
        }
        expect(
          counts[defaultTargetPlatform == TargetPlatform.android
              ? 'surfaces'
              : 'heldDrawables'],
          0,
        );
        debugPrint(
          'Atmosphere qualification: frames=$frames; presentation readbacks=0; cleanup=$counts',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await controller.whenDisposed;
        await listener.cancel();
        await tester.binding.setSurfaceSize(null);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
