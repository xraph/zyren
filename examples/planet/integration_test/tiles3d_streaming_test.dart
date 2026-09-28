import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/tiles3d_lab.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native 3D Tiles refinement, fallback, retry and cleanup', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    final key = GlobalKey<Tiles3DLabState>();
    await tester.pumpWidget(Tiles3DLabApp(labKey: key));
    final lab = key.currentState!;
    final controller = lab.controller;
    var frames = 0;
    final subscription = controller.frameStats.listen((stats) {
      expectSync(stats.readbackBytes, 0);
      frames++;
    });
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 400; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        if (lab.loadError != null) fail('${lab.loadError}');
        if (controller.status.value case SceneFailed(:final issue)) {
          fail('$issue');
        }
        if (done()) return;
        if (i % 10 == 0) controller.invalidate();
      }
      fail(
        'Tiles did not settle: ${lab.tiles?.stats?.visibleTiles} visible, '
        '${lab.tiles?.stats?.activeRequests} loading; ${lab.tiles?.failures}',
      );
    }

    try {
      await until(() => frames > 0 && lab.tiles?.stats?.activeRequests == 0);
      expect(lab.tiles!.visibleTileIds, {'0'});
      await tester.tap(find.text('Detail'));
      await until(
        () =>
            lab.tiles!.visibleTileIds.length > 1 &&
            lab.tiles!.stats!.activeRequests == 0,
      );
      final count = lab.tiles!.visibleTileIds.length;
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('$count tiles · 0 loading'), findsOneWidget);
      await tester.tap(find.text('Overview'));
      await until(() => lab.tiles!.visibleTileIds.length == 1);
      await tester.pump();
      expect(find.text('1 tiles · 0 loading'), findsOneWidget);
      await tester.tap(find.text('Detail'));
      await until(() => lab.tiles!.visibleTileIds.length == count);
      await tester.pump();
      expect(find.text('$count tiles · 0 loading'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await until(
        () =>
            lab.tiles!.failures.isNotEmpty &&
            lab.tiles!.stats!.activeRequests == 0,
      );
      expect(lab.tiles!.visibleTileIds, {'0'});
      expect(find.textContaining('parent remains visible'), findsOneWidget);
      await tester.tap(find.text('Reconnect and retry'));
      await until(
        () =>
            lab.tiles!.failures.isEmpty &&
            lab.tiles!.visibleTileIds.length > 1 &&
            lab.tiles!.stats!.activeRequests == 0,
      );
      final before = frames;
      await tester.binding.setSurfaceSize(const Size(390, 700));
      await until(() => frames > before);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(430));
      debugPrint(
        '3D Tiles native: $count detail tiles, $frames frame samples.',
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
    for (final name in [
      'sessions',
      'renderers',
      'retiring',
      'readbackBytes',
      android ? 'surfaces' : 'heldDrawables',
    ]) {
      expect(diagnostics![name], 0, reason: name);
    }
    debugPrint('3D Tiles cleanup: $diagnostics');
  });
}
