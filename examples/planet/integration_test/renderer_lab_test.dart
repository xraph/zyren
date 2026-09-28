import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/renderer_lab.dart';
import 'package:shader_lab/shader_lab.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'physical renderer presents two views, resizes and releases native owners',
    (tester) async {
      final fixtures = [RendererFixture(), RendererFixture()];
      final controllers = fixtures.map(rendererLabController).toList();
      final frames = [0, 0];
      final listeners = [
        for (var i = 0; i < 2; i++)
          controllers[i].frameStats.listen((stats) {
            expectSync(stats.readbackBytes, 0);
            frames[i]++;
          }),
      ];
      final channel = MethodChannel(
        defaultTargetPlatform == TargetPlatform.android
            ? 'zyren/android-surfaces'
            : 'zyren/scene-views',
      );
      Future<void> waitFrame(int index, int previous) async {
        for (var attempt = 0; attempt < 240; attempt++) {
          await tester.pump(const Duration(milliseconds: 25));
          if (controllers[index].status.value case SceneFailed(:final issue)) {
            fail('$issue');
          }
          if (frames[index] > previous) return;
          if (attempt % 10 == 0) controllers[index].invalidate();
        }
        fail('Renderer view $index did not present.');
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  for (final controller in controllers)
                    Expanded(
                      child: SceneView(
                        controller: controller,
                        resolutionScale: .5,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        await waitFrame(0, 0);
        await waitFrame(1, 0);
        for (final fixture in fixtures) {
          expect(fixture.scene.environment, isNotNull);
          expect(fixture.scene.renderSettings.sampleCount, 4);
        }
        await tester.binding.setSurfaceSize(const Size(390, 700));
        final before = List<int>.from(frames);
        fixtures[0].instances.setTransform(
          0,
          Mat4.compose(
            const Vec3(0, 1, 1),
            Quat.identity,
            const Vec3(.4, .4, .4),
          ),
        );
        fixtures[1].scene.renderSettings = fixtures[1].scene.renderSettings
            .copyWith(clearBloom: true, sampleCount: 1);
        await waitFrame(0, before[0]);
        await waitFrame(1, before[1]);
        await tester.pumpWidget(const SizedBox());
        for (final controller in controllers) {
          controller.dispose();
          await controller.whenDisposed;
        }
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
          'Renderer qualification: frames=$frames; presentation readbacks=0; cleanup=$counts',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        for (final controller in controllers) {
          controller.dispose();
          await controller.whenDisposed;
        }
        for (final listener in listeners) {
          await listener.cancel();
        }
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
  testWidgets(
    'material lab keeps its controls and canvas usable at narrow widths',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      await tester.pumpWidget(const RendererLabApp());
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      var frames = 0;
      final listener = controller.frameStats.listen((stats) {
        expectSync(stats.readbackBytes, 0);
        frames++;
      });
      try {
        for (var i = 0; i < 240 && frames == 0; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          if (controller.status.value case SceneFailed(:final issue)) {
            fail('$issue');
          }
        }
        expect(frames, greaterThan(0));
        for (final width in [1000.0, 320.0, 390.0]) {
          await tester.binding.setSurfaceSize(Size(width, 700));
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
          final padding = tester.view.padding;
          final usableHeight =
              700 -
              (padding.top + padding.bottom) / tester.view.devicePixelRatio;
          expect(
            tester.getSize(find.byType(SceneView)).height,
            greaterThan(usableHeight * .70),
            reason:
                'Keep the canvas above 70% of usable height, excluding system safe areas.',
          );
          expect(find.text('Material lab'), findsOneWidget);
        }
        await tester.tap(find.byType(Switch));
        await tester.pump();
        expect(controller.scene.renderSettings.bloom, isNull);
        await tester.tap(find.text('Reset view'));
        await tester.pump();
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await controller.whenDisposed;
        await listener.cancel();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}
