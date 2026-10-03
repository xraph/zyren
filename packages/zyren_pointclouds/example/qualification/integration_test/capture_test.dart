import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reality_capture/main.dart';
import 'support/native_scene_checks.dart' as native_checks;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  native_checks.main();
  testWidgets(
    'native imports, streamed points, perspective splats, controls and cleanup',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(const RealityCaptureLab());
        final state = tester.state<CaptureWorkbenchState>(
          find.byType(CaptureWorkbench),
        );
        for (var i = 0; i < 1200 && !state.ready && state.error == null; i++) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(state.error, isNull);
        expect(state.ready, isTrue);
        for (
          var i = 0;
          i < 1200 &&
              (state.frameStats == null ||
                  state.points!.stream.isLoading ||
                  state.splats!.stream.isLoading ||
                  state.splats!.renderer == null ||
                  state.splats!.renderer!.projected.isEmpty);
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(state.frameStats, isNotNull);
        expect(state.frameStats!.readbackBytes, 0);
        expect(
          state.imported['survey.las']!.pointAt(1).x,
          closeTo(1e9 + .001, 1e-7),
        );
        expect(state.imported['survey.laz']!.classificationAt(1), 2);
        expect(
          state.imported['survey14.laz']!.attributesAt(1)['intensity'],
          1201,
        );
        expect(state.imported['scans.e57']!.identityAt(1).$3, 2);
        expect(state.points!.stream.visible, isNotEmpty);
        expect(state.splats!.stream.visible, isNotEmpty);
        expect(state.splats!.renderer!.projected, isNotEmpty);
        expect(
          find.bySemanticsLabel('Native point and Gaussian viewport'),
          findsOneWidget,
        );
        await tester.tap(find.text('Ground only'));
        for (var i = 0; i < 400 && state.points!.hasPendingUpdate; i++) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(state.points!.hasPendingUpdate, isFalse);
        expect(state.filtered, isTrue);
        for (final cloud in state.points!.visibleClouds.values) {
          for (var i = 0; i < cloud.data.count; i++) {
            expect(cloud.data.classificationAt(i), 2);
          }
        }
        await tester.tap(find.text('Section'));
        await tester.pump(const Duration(milliseconds: 250));
        expect(state.viewport!.scene.clippingPlanes.length, 1);
        await tester.tap(find.text('Clear section'));
        await tester.tap(find.text('Show all classes'));
        for (var i = 0; i < 400 && state.points!.hasPendingUpdate; i++) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(state.points!.hasPendingUpdate, isFalse);
        expect(tester.takeException(), isNull);
        await state.viewport!.setPlugins([]);
        expect(state.points!.stream.isClosed, isFalse);
        expect(state.splats!.stream.isClosed, isFalse);
        expect(state.points!.object.children, isEmpty);
        expect(state.splats!.object.children, isEmpty);
        await state.viewport!.setPlugins([state.points!, state.splats!]);
        for (
          var i = 0;
          i < 400 &&
              (state.points!.hasPendingUpdate ||
                  state.splats!.renderer == null ||
                  state.splats!.renderer!.projected.isEmpty);
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(state.points!.visibleClouds, isNotEmpty);
        expect(state.splats!.renderer!.projected, isNotEmpty);
        debugPrint(
          'REALITY_CAPTURE_QUALIFICATION ${jsonEncode({'backend': state.backend, 'imports': state.imported.map((k, v) => MapEntry(k, v.count)), 'points': state.points!.stream.stats.toJson(), 'gaussians': state.splats!.stream.stats.toJson(), 'projected': state.splats!.renderer!.projected.length, 'readbackBytes': state.frameStats!.readbackBytes, 'filter': 'passed', 'section': 'passed', 'semantics': 'passed'})}',
        );
        final disposed = state.whenDisposed;
        await tester.pumpWidget(const SizedBox.shrink());
        await disposed;
        expect(state.points!.stream.isClosed, isTrue);
        expect(state.splats!.stream.isClosed, isTrue);
        expect(state.points!.stream.stats.decodedBytes, 0);
        expect(state.splats!.stream.stats.decodedBytes, 0);
        debugPrint('REALITY_CAPTURE_CLEANUP passed');
      } finally {
        semantics.dispose();
      }
    },
  );
}
