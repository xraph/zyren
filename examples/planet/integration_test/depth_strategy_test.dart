import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/depth_lab.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native depth modes, range changes, MSAA, resize and cleanup', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    final fixture = DepthFixture();
    await tester.pumpWidget(DepthLabApp(fixture: fixture));
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    var frames = 0;
    final subscription = controller.frameStats.listen((stats) {
      expectSync(stats.readbackBytes, 0);
      frames++;
    });
    Future<void> nextFrame() async {
      final before = frames;
      controller.invalidate();
      for (var i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        if (controller.status.value case SceneFailed(:final issue)) {
          fail('$issue');
        }
        if (frames > before) return;
        if (i % 10 == 0) controller.invalidate();
      }
      fail('No presented depth frame');
    }

    try {
      await nextFrame();
      for (final strategy in [DepthStrategy.standard, DepthStrategy.reversed]) {
        await tester.tap(find.byType(DropdownButton<DepthStrategy>));
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .text(
                strategy == DepthStrategy.reversed ? 'Reversed' : 'Standard',
              )
              .last,
        );
        await tester.pumpAndSettle();
        expect(fixture.camera.depthStrategy, strategy);
        for (final range in DepthRange.values) {
          await tester.tap(find.text(range.label));
          await nextFrame();
          expect(fixture.range, range);
        }
        await tester.tap(find.byType(Switch));
        await nextFrame();
      }
      await tester.binding.setSurfaceSize(const Size(390, 700));
      await nextFrame();
      expect(tester.takeException(), isNull);
      debugPrint(
        'Depth narrow: canvas=${tester.getSize(find.byType(SceneView))}; padding=${tester.view.padding}; ratio=${tester.view.devicePixelRatio}',
      );
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(430));
      debugPrint(
        'Depth native: $frames sampled frames; both modes and all ranges; zero readbacks',
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      await controller.whenDisposed;
      await subscription.cancel();
      await tester.binding.setSurfaceSize(null);
    }
    final android = defaultTargetPlatform == TargetPlatform.android;
    final diagnostics = await MethodChannel(
      android ? 'zyren/android-surfaces' : 'zyren/scene-views',
    ).invokeMapMethod<Object?, Object?>('diagnostics');
    for (final key in [
      'sessions',
      'renderers',
      'retiring',
      'readbackBytes',
      android ? 'surfaces' : 'heldDrawables',
    ]) {
      expect(diagnostics![key], 0, reason: key);
    }
    debugPrint('Depth cleanup: $diagnostics');
  });
}
