import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/terrain_lab.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native terrain flights, offline fallback, retry and cleanup', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    final fixture = TerrainFixture();
    await tester.pumpWidget(TerrainLabApp(fixture: fixture));
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    var frames = 0;
    final subscription = controller.frameStats.listen((stats) {
      expectSync(stats.readbackBytes, 0);
      frames++;
    });
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        if (controller.status.value case SceneFailed(:final issue)) {
          fail('$issue');
        }
        if (done()) return;
        if (i % 10 == 0) controller.invalidate();
      }
      fail(
        'Terrain condition timed out: ${fixture.terrain.stats?.visibleTiles} visible, '
        '${fixture.terrain.stats?.activeRequests} loading; ${fixture.terrain.failures}',
      );
    }

    try {
      await until(
        () => frames > 0 && fixture.terrain.stats?.activeRequests == 0,
      );
      expect(fixture.terrain.visibleCoordinates.length, 1);
      await tester.tap(find.text('Detail'));
      await until(
        () =>
            fixture.terrain.visibleCoordinates.length > 1 &&
            fixture.terrain.stats?.activeRequests == 0,
      );
      final detailTiles = fixture.terrain.visibleCoordinates.length;
      // Status must settle without another camera event or sampled GPU frame.
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('$detailTiles tiles · 0 loading'), findsOneWidget);
      for (final view in ['East', 'West', 'Overview', 'Detail']) {
        await tester.tap(find.text(view));
        controller.invalidate();
        await until(
          () =>
              fixture.terrain.stats?.activeRequests == 0 &&
              fixture.terrain.visibleCoordinates.isNotEmpty,
        );
        final stats = fixture.terrain.stats!;
        expect(
          stats.cachedBytes + stats.reservedBytes,
          lessThanOrEqualTo(fixture.terrain.budget.maxDecodedBytes),
        );
        expect(
          stats.residentBytes,
          lessThanOrEqualTo(fixture.terrain.budget.maxResidentBytes),
        );
        expect(
          stats.activeRequests,
          lessThanOrEqualTo(fixture.terrain.budget.maxRequests),
        );
      }
      await tester.tap(find.byType(Switch));
      await until(
        () =>
            fixture.terrain.failures.isNotEmpty &&
            fixture.terrain.stats?.activeRequests == 0,
      );
      expect(fixture.terrain.visibleCoordinates.length, 1);
      expect(
        find.textContaining('parent terrain remains visible'),
        findsOneWidget,
      );
      await tester.tap(find.text('Reconnect and retry'));
      await until(
        () =>
            fixture.terrain.failures.isEmpty &&
            fixture.terrain.visibleCoordinates.length > 1 &&
            fixture.terrain.stats?.activeRequests == 0,
      );
      final beforeResize = frames;
      await tester.binding.setSurfaceSize(const Size(390, 700));
      await until(() => frames > beforeResize);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(430));
      debugPrint(
        'Terrain native: $detailTiles detail tiles, $frames samples; '
        '${fixture.terrain.stats!.cachedBytes} cached bytes, ${fixture.terrain.stats!.residentBytes} resident payload',
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
    debugPrint('Terrain cleanup: $diagnostics');
  });
}
