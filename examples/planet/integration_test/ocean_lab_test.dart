import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/ocean/ocean_page.dart';
import 'package:planet/main.dart';
import 'package:planet/scene_launcher.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native scenes switch, pause and preserve independent layer state',
    (tester) async {
      final storage = await Directory.systemTemp.createTemp('ocean-lab-app-');
      OceanLabPageState? lastState;
      await tester.pumpWidget(
        PlanetApp(
          home: GeospatialSceneLauncher(
            sceneBuilder: (demo) => OceanLabPage(
              storageDirectory: storage,
              initialScene: demo.id.split('.').last,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('scene-ocean.calm')));
      await tester.pump(const Duration(milliseconds: 300));
      Future<OceanLabPageState> ready(String id) async {
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 25));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          final state = tester.state<OceanLabPageState>(
            find.byType(OceanLabPage),
          );
          final controller = state.controller;
          if (controller?.status.value case SceneFailed(:final issue)) {
            fail('$issue');
          }
          if (state.world?.definition.id == id &&
              controller?.latestFrameStats != null &&
              state.world!.host.clock.tick >= 6 &&
              state.world!.presentation!.isReady) {
            final stats = controller!.latestFrameStats!;
            expect(stats.readbackBytes, 0);
            debugPrint(
              'Ocean native scene $id: revision=${state.world!.definition.revision}; tick=${state.world!.host.clock.tick}; frame=${stats.frameId}; readback=${stats.readbackBytes}; size=${stats.physicalSize.width}x${stats.physicalSize.height}',
            );
            lastState = state;
            return state;
          }
        }
        final state = tester.state<OceanLabPageState>(
          find.byType(OceanLabPage),
        );
        fail(
          'Native scene $id did not present within 90 seconds: '
          '${state.controller?.status.value.runtimeType}, '
          'ready=${state.world?.presentation?.isReady}, '
          'tick=${state.world?.host.clock.tick}, '
          'frame=${state.controller?.latestFrameStats?.frameId}.',
        );
      }

      try {
        final initial = await ready('calm');
        expect(initial.controller!.latestFrameStats!.readbackBytes, 0);
        final canvasBounds = tester.getRect(
          find.byKey(const Key('lab-canvas')),
        );
        final originalController = initial.controller;
        await tester.tap(find.byKey(const ValueKey('info-toggle')));
        await tester.pump();
        expect(
          tester.getRect(find.byKey(const Key('lab-canvas'))),
          canvasBounds,
        );
        await tester.tap(find.byKey(const ValueKey('panel-close')));
        await tester.pump();
        expect(initial.controller, same(originalController));
        expect(
          tester.getRect(find.byKey(const Key('lab-canvas'))),
          canvasBounds,
        );
        if (find.byKey(const ValueKey('controls-panel')).evaluate().isEmpty) {
          await tester.tap(find.byKey(const ValueKey('controls-toggle')));
          await tester.pump();
        }
        await tester.ensureVisible(find.byTooltip('Pause simulation'));
        await tester.pump();
        await tester.tap(find.byTooltip('Pause simulation'));
        await tester.pump(const Duration(milliseconds: 200));
        final tick = initial.world!.host.clock.tick;
        await tester.pump(const Duration(milliseconds: 300));
        expect(initial.world!.host.clock.tick, tick);
        await tester.ensureVisible(find.widgetWithText(FilterChip, 'foam'));
        await tester.pump();
        await tester.tap(find.widgetWithText(FilterChip, 'foam'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          initial.world!.host.layers
              .layer(initial.world!.ocean.foamLayerId)
              .visible,
          isFalse,
        );
        expect(
          initial.world!.host.layers
              .layer(initial.world!.ocean.surfaceLayerId)
              .visible,
          isTrue,
        );
        for (final name in [
          'Storm swell',
          'Shallow coast',
          'Buoyant vessel',
          'Below the surface',
          'Orbit to surface',
        ]) {
          await tester.ensureVisible(
            find.byKey(const ValueKey('lab-select-Scene')),
          );
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('lab-select-Scene')));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.text(name).last);
          await tester.pump(const Duration(milliseconds: 300));
          final id = {
            'Storm swell': 'storm',
            'Shallow coast': 'coast',
            'Buoyant vessel': 'vessel',
            'Below the surface': 'underwater',
            'Orbit to surface': 'orbit',
          }[name]!;
          final next = await ready(id);
          expect(next.world!.simulationFailure, isNull);
        }
        await tester.tap(find.byTooltip('All scenes'));
        final closingDeadline = DateTime.now().add(const Duration(seconds: 15));
        while (lastState!.mounted && DateTime.now().isBefore(closingDeadline)) {
          await tester.pump(const Duration(milliseconds: 25));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(lastState!.mounted, isFalse);
        await tester.runAsync(() async {
          await lastState?.whenClosed;
        });
        expect(find.text('Geospatial scenes'), findsOneWidget);
        expect(lastState!.controller!.isDisposed, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await lastState?.whenClosed;
        });
        await storage.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
