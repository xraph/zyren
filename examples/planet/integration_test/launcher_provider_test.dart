import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/main.dart';
import 'package:planet/google_tiles_lab.dart';
import 'package:planet/scene_launcher.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('unified launcher retains provider access in both Earth scenes', (
    tester,
  ) async {
    expect(
      GoogleTilesLabState.configured,
      isTrue,
      reason:
          'Build through tool/planet.py with the private provider configuration.',
    );
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    final records = <Map<String, Object?>>[];
    final report = <String, dynamic>{
      'platform': Platform.operatingSystem,
      'providerConfigured': true,
      'scenes': records,
      'passed': false,
    };
    binding.reportData = report;
    await tester.pumpWidget(const PlanetApp());
    try {
      for (final id in ['photorealistic', 'clouds']) {
        await tester.ensureVisible(find.byKey(ValueKey('scene-$id')));
        await tester.tap(find.byKey(ValueKey('scene-$id')));
        await tester.pump(const Duration(milliseconds: 350));
        final lab = tester.state<GoogleTilesLabState>(
          find.byType(GoogleTilesLab),
        );
        final deadline = DateTime.now().add(const Duration(minutes: 3));
        var ready = false;
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 25));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          if (lab.loadError != null) {
            fail('Provider failed: ${lab.loadError.runtimeType}.');
          }
          if (lab.controller.status.value case SceneFailed(:final issue)) {
            fail('Native scene failed: ${issue.code}.');
          }
          final frame = lab.controller.latestFrameStats;
          if (frame != null &&
              (lab.tiles?.stats?.visibleTiles ?? 0) > 0 &&
              lab.tiles!.attributions.isNotEmpty &&
              (id != 'clouds' ||
                  lab
                          .profile
                          .cloudLayer!
                          .controller
                          .history
                          .accumulatedFrames >=
                      16)) {
            final viewport = tester.getSize(find.byType(SceneView));
            final hit = await lab.controller.pick(
              ViewportPoint(viewport.width / 2, viewport.height / 2),
            );
            if (hit != null) {
              ready = true;
              break;
            }
          }
        }
        expect(
          ready,
          isTrue,
          reason: '$id did not display provider tiles before the deadline.',
        );
        final stats = lab.controller.latestFrameStats!;
        expect(stats.readbackBytes, 0);
        final renderer = await lab.controller.ready;
        expect(renderer.presentationPath.name, isNot('readback'));
        records.add({
          'scene': id,
          'preset': lab.preset.name,
          'backend': renderer.backend,
          'presentation': renderer.presentationPath.name,
          'visibleTiles': lab.tiles!.stats!.visibleTiles,
          'sourceCredits': lab.tiles!.attributions.length,
          'centerPick': true,
          'readbackBytes': stats.readbackBytes,
          'cloudHistoryFrames':
              lab.profile.cloudLayer?.controller.history.accumulatedFrames,
        });
        debugPrint(
          'Provider launcher $id: ${lab.tiles!.stats!.visibleTiles} visible tiles; native ${renderer.backend}.',
        );
        await tester.tap(find.byTooltip('All scenes'));
        await tester.pump(const Duration(milliseconds: 400));
        await lab.whenClosed;
        await tester.pumpAndSettle();
        expect(find.byType(GeospatialSceneLauncher), findsOneWidget);
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    }
    final android = Platform.isAndroid;
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
    report['cleanup'] = 'passed';
    report['passed'] = true;
  });
}
