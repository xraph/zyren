import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/google_tiles_lab.dart';
import 'package:planet/geospatial_presets.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Google Maps live tiles use native presentation and release', (
    tester,
  ) async {
    expect(
      GoogleTilesLabState.configured,
      isTrue,
      reason: 'Provide authorized access through dart-define-from-file.',
    );
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    final key = GlobalKey<GoogleTilesLabState>();
    await tester.pumpWidget(GoogleTilesLabApp(labKey: key));
    final lab = key.currentState!;
    var initialPosition = lab.controller.camera.position;
    var initialTarget = lab.controller.camera.target;
    var frames = 0;
    final subscription = lab.controller.frameStats.listen((frame) {
      expectSync(frame.readbackBytes, 0);
      frames++;
    });
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 2400; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        if (lab.loadError != null) {
          fail(
            'Provider initialization failed (${lab.loadError.runtimeType}).',
          );
        }
        if (lab.controller.status.value case SceneFailed(:final issue)) {
          fail('${issue.code}: ${issue.message}; ${issue.cause}');
        }
        expect(
          lab.controller.camera.position.distanceTo(initialPosition),
          lessThan(10000),
          reason:
              'Camera displaced while tiles load: ${lab.controller.camera.position}.',
        );
        if (ready()) return;
        if (i % 20 == 0) lab.controller.invalidate();
      }
      fail(
        'Live scene timed out: ${lab.tiles?.stats?.visibleTiles} visible; ${lab.tiles?.failures.map((f) => f.code.name).toSet()}.',
      );
    }

    try {
      for (final preset in GoogleTilesPreset.values) {
        if (lab.preset != preset) {
          await tester.tap(find.text(preset.label));
          await tester.pump();
          initialPosition = lab.controller.camera.position;
          initialTarget = lab.controller.camera.target;
        }
        final beforePreset = frames;
        lab.controller.invalidate();
        await until(
          () =>
              frames > beforePreset &&
              (lab.tiles?.stats?.visibleTiles ?? 0) > 0 &&
              lab.tiles!.attributions.isNotEmpty,
        );
        var settled = 0;
        await until(() {
          if (lab.tiles!.stats!.activeRequests == 0) {
            settled++;
          } else {
            settled = 0;
          }
          return settled > 40;
        });
        debugPrint(
          'Preset displacement: ${lab.controller.camera.position.distanceTo(initialPosition).round()} m.',
        );
        expect(lab.tiles!.failures, isEmpty);
        final viewport = tester.getSize(find.byType(SceneView));
        final hit = await lab.controller.pick(
          ViewportPoint(viewport.width / 2, viewport.height / 2),
        );
        expect(
          hit,
          isNotNull,
          reason: 'The city center must contain rendered geometry.',
        );
        expect(
          hit!.point.distanceTo(initialTarget),
          lessThan(5000),
          reason: 'The loaded surface must be near the ${preset.label} preset.',
        );
        debugPrint(
          'Visible hierarchy depths: ${lab.tiles!.visibleTileIds.map((id) => id.split('/').length).toSet()}.',
        );
        expect(
          lab.controller.camera.position.distanceTo(initialPosition),
          lessThan(10000),
          reason: 'Loading terrain must preserve the city camera pose.',
        );
        expect(lab.profile.air.controller.date, preset.utcDate(year: 2026));
        expect(
          lab.controller.scene.renderSettings.toneMapping,
          ToneMapping.agx,
        );
        expect(lab.controller.scene.renderSettings.exposure, preset.exposure);
        expect(lab.controller.scene.effects.length, greaterThanOrEqualTo(27));
        expect(lab.profile.effects.controller.width, lessThanOrEqualTo(640));
        expect(lab.profile.effects.controller.height, lessThanOrEqualTo(640));
        debugPrint(
          '${preset.label} combined scene: ${lab.tiles!.stats!.visibleTiles} tiles, ${lab.controller.scene.effects.length} effects.',
        );
      }
      expect(find.text('Google Maps'), findsWidgets);
      expect(find.text('Data sources'), findsOneWidget);
      await tester.binding.setSurfaceSize(const Size(390, 700));
      final before = frames;
      await until(() => frames > before);
      await tester.tap(find.text('Data sources'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(find.text('Close'), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugPrint(
        'Google native: ${lab.tiles!.stats!.visibleTiles} visible, $frames frames, ${lab.tiles!.attributions.length} source credits.',
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      await lab.whenClosed;
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
    debugPrint('Google native cleanup: $diagnostics');
  });
}
