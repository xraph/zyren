import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/main.dart';
import 'package:planet/layers/fixture.dart';
import 'package:planet/layers/layers_lab.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native layer controls switch rigs, recover sources and restore a saved layout',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'zyren-layer-lab-',
      );
      final file = File('${directory.path}/layout.json');
      final fixture = LayersFixture();
      SceneController? session;
      Future<void> waitFor(bool Function() ready) async {
        for (var i = 0; i < 400; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (session?.status.value case SceneFailed(:final issue)) {
            fail('$issue');
          }
          if (ready()) return;
        }
        fail('Layer lab did not reach the expected state.');
      }

      try {
        await tester.binding.setSurfaceSize(const Size(1000, 700));
        await tester.pumpWidget(
          PlanetApp(
            home: LayersLab(fixture: fixture, layoutFile: file),
          ),
        );
        await waitFor(() => find.byType(SceneView).evaluate().isNotEmpty);
        session = tester.widget<SceneView>(find.byType(SceneView)).controller!;
        await waitFor(
          () =>
              fixture.geo.layers.snapshot.length == 3 &&
              fixture.geo.layers.layer('west').status.data ==
                  GeoLayerDataState.ready &&
              fixture.geo.layers.layer('east').status.data ==
                  GeoLayerDataState.ready,
        );
        final before = session.camera.position;
        await tester.tap(find.text('Detail'));
        await waitFor(() => session!.camera.position != before);
        expect(fixture.geo.cameras.activeRigId, 'detail');
        await tester.tap(find.text('Fail east source'));
        await waitFor(
          () =>
              fixture.geo.layers.layer('east').status.data ==
                  GeoLayerDataState.failed &&
              fixture.geo.layers.layer('west').status.data ==
                  GeoLayerDataState.ready,
        );
        expect(
          fixture.geo.layers.layer('west').status.data,
          GeoLayerDataState.ready,
        );
        await tester.tap(find.text('Retry east source'));
        await waitFor(
          () =>
              fixture.geo.layers.layer('east').status.data ==
              GeoLayerDataState.ready,
        );
        await tester.tap(find.widgetWithText(FilterChip, 'West · ready'));
        await waitFor(() => !fixture.geo.layers.layer('west').visible);
        await tester.tap(find.text('Save layout'));
        await waitFor(() => find.text('Layout saved').evaluate().isNotEmpty);
        expect(await file.exists(), isTrue);
        for (final width in [390.0, 1000.0]) {
          await tester.binding.setSurfaceSize(Size(width, 700));
          session.invalidate();
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull);
          expect(
            tester.getSize(find.byType(SceneView)).height,
            greaterThan(400),
          );
          expect(find.text('Save layout'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
        await session.whenDisposed;
        final restored = LayersFixture();
        await tester.pumpWidget(
          PlanetApp(
            home: LayersLab(fixture: restored, layoutFile: file),
          ),
        );
        session = null;
        await waitFor(() => find.byType(SceneView).evaluate().isNotEmpty);
        session = tester.widget<SceneView>(find.byType(SceneView)).controller!;
        await waitFor(() => session!.status.value is SceneReady);
        expect(restored.geo.layers.layer('west').visible, isFalse);
        expect(restored.geo.layers.layer('east').visible, isTrue);
        expect(find.text('Saved layout restored'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        session?.dispose();
        await session?.whenDisposed;
        await directory.delete(recursive: true);
        await tester.binding.setSurfaceSize(null);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
