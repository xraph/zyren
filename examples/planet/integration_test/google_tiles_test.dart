import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/google_tiles_lab.dart';
import 'package:planet/geospatial_presets.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../test_support/asset_fingerprints.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Google Maps live tiles use native presentation and release', (
    tester,
  ) async {
    expect(
      GoogleTilesLabState.configured,
      isTrue,
      reason: 'Provide authorized access through dart-define-from-file.',
    );
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    const selected = String.fromEnvironment('ZYREN_STORY_PRESET');
    final initial = selected.isEmpty
        ? null
        : GoogleTilesPreset.values.byName(selected);
    final key = GlobalKey<GoogleTilesLabState>();
    final manifest =
        jsonDecode(
              await rootBundle.loadString(
                'assets/qualification/source_assets.json',
              ),
            )
            as Map<String, dynamic>;
    final assets =
        AssetFingerprints(SceneRuntime.defaultAssetServices.resolver, {
          for (final asset in manifest['assets'] as List)
            Uri.parse(asset['uri'] as String),
        });
    await tester.pumpWidget(
      GoogleTilesLabApp(
        labKey: key,
        initialPreset: initial,
        assetServices: assets.wrap(SceneRuntime.defaultAssetServices),
      ),
    );
    final lab = key.currentState!;
    final records = <Map<String, Object?>>[];
    final report = <String, dynamic>{
      'schema': 2,
      'suite': 'geospatial-native-stories',
      'platform': defaultTargetPlatform.name,
      'passed': false,
      'cleanup': 'not run',
      'scenes': records,
    };
    binding.reportData = report;
    var initialPosition = lab.controller.camera.position;
    var initialTarget = lab.controller.camera.target;
    var frames = 0;
    FrameStats? lastFrame;
    final progress = Stopwatch()..start();
    var reportedAt = 0;
    final subscription = lab.controller.frameStats.listen((frame) {
      expectSync(frame.readbackBytes, 0);
      lastFrame = frame;
      frames++;
      if (progress.elapsed.inSeconds - reportedAt >= 5) {
        reportedAt = progress.elapsed.inSeconds;
        final history = lab.profile.cloudLayer?.controller.history;
        debugPrint(
          'Native progress: frame ${frame.frameId}, '
          '${lab.tiles?.stats?.visibleTiles} visible, '
          '${lab.tiles?.stats?.activeRequests} loading; '
          'cloud history ${history?.accumulatedFrames} (${history?.reason.name}).',
        );
      }
    });
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 2400; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
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
        'Live scene timed out: ${lab.tiles?.stats?.visibleTiles} visible; ${lab.tiles?.failures.map((f) => '${f.code.name} HTTP ${f.httpStatus}').toSet()}.',
      );
    }

    try {
      final presets = lab.presets
          .where((preset) => selected.isEmpty || preset.name == selected)
          .toList();
      expect(presets, isNotEmpty, reason: 'Unknown story preset: $selected');
      for (final preset in presets) {
        if (lab.preset != preset) {
          await tester.tap(find.text(preset.label));
          await tester.pump();
          initialPosition = lab.controller.camera.position;
          initialTarget = lab.controller.camera.target;
        }
        expect(
          lab.preset,
          preset,
          reason: 'The requested preset must be active.',
        );
        final beforePreset = frames;
        lab.controller.invalidate();
        await until(
          () =>
              frames > beforePreset &&
              (lab.tiles?.stats?.visibleTiles ?? 0) > 0 &&
              lab.tiles!.attributions.isNotEmpty,
        );
        var settled = 0;
        var retries = 0;
        var retryFrame = frames;
        await until(() {
          if (lab.tiles!.failures.isNotEmpty &&
              retries < 2 &&
              frames > retryFrame + 10) {
            retries++;
            retryFrame = frames;
            debugPrint(
              '${preset.label}: retry $retries for '
              '${lab.tiles!.failures.map((failure) => '${failure.code.name} HTTP ${failure.httpStatus}').toSet()}.',
            );
            lab.tiles!.retryFailed();
            settled = 0;
          }
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
        debugPrint(
          '${preset.label}: ${lab.tiles!.stats!.visibleTiles} tiles, '
          '${lab.tiles!.stats!.residentBytes} resident bytes.',
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
        expect(lab.profile.effects.controller.width, lessThanOrEqualTo(1920));
        expect(lab.profile.effects.controller.height, lessThanOrEqualTo(1920));
        expect(
          lab.profile.effects.controller.width *
              lab.profile.effects.controller.height,
          lessThanOrEqualTo(2097152),
        );
        if (lab.profile.cloudLayer case final cloud?) {
          expect(cloud.controller.parameters.coverage, preset.coverage);
          expect(cloud.controller.quality, CloudQualityPreset.high);
          expect(
            cloud.controller.history.accumulatedFrames,
            greaterThanOrEqualTo(16),
          );
        }
        debugPrint(
          '${preset.label} combined scene: ${lab.tiles!.stats!.visibleTiles} tiles, ${lab.controller.scene.effects.length} effects.',
        );
        final renderer = await lab.controller.ready;
        records.add({
          'sourcePath':
              'storybook/src/${preset.coverage == null ? 'atmosphere' : 'clouds'}/3DTilesRenderer.stories.tsx',
          'export': preset.label,
          'preset': preset.name,
          'rendering': 'passed',
          'comparison': 'not run',
          'backend': renderer.backend,
          'adapter': renderer.adapterName,
          'presentation': renderer.presentationPath.name,
          'logicalViewport': [viewport.width, viewport.height],
          'physicalViewport': [
            lastFrame!.physicalSize.width,
            lastFrame!.physicalSize.height,
          ],
          'assets': assets.records,
          'inputs': {
            'longitude': preset.longitude,
            'latitude': preset.latitude,
            'heading': preset.heading,
            'pitch': preset.pitch,
            'distance': preset.distance,
            'exposure': preset.exposure,
            'date': lab.profile.air.controller.date.toIso8601String(),
            'cloudCoverage': preset.coverage,
            'cloudWeatherAnimated': preset.coverage != null,
          },
          'checks': {
            'centerPickDistance': hit.point.distanceTo(initialTarget),
            'cameraDisplacement': lab.controller.camera.position.distanceTo(
              initialPosition,
            ),
            'visibleTiles': lab.tiles!.stats!.visibleTiles,
            'tilePayloadBytes': lab.tiles!.stats!.residentBytes,
            'effects': lab.controller.scene.effects.length,
            'cloudHistoryFrames':
                lab.profile.cloudLayer?.controller.history.accumulatedFrames,
            'readbackBytes': lastFrame!.readbackBytes,
            'sourceCredits': lab.tiles!.attributions.length,
            'retries': retries,
          },
        });
      }
      expect(find.text('Google Maps'), findsWidgets);
      expect(find.text('Data sources'), findsOneWidget);
      await tester.binding.setSurfaceSize(const Size(390, 700));
      final before = frames;
      await until(() => frames > before + 2);
      expect(
        lastFrame!.physicalSize.width * lastFrame!.physicalSize.height,
        lessThanOrEqualTo(2097152),
      );
      await tester.tap(find.text('Data sources'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(find.text('Close'), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugPrint(
        'Google native: ${lab.tiles!.stats!.visibleTiles} visible, $frames frames, ${lab.tiles!.attributions.length} source credits.',
      );
    } catch (error, stack) {
      debugPrint('Live scene failed before cleanup: $error\n$stack');
      rethrow;
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
    report['cleanup'] = 'passed';
    report['passed'] = true;
    report['diagnostics'] = {
      for (final entry in diagnostics!.entries)
        entry.key.toString(): entry.value,
    };
  });
}
