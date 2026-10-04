import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:planet/atmosphere_lab.dart';
import 'package:planet/camera_lab.dart';
import 'package:planet/terrain_lab.dart';
import 'package:planet/tiles3d_lab.dart';
import 'package:planet/planet_page.dart';
import 'package:planet/layers/layers_lab.dart';
import 'package:planet/layers/offline.dart';
import 'package:planet/photorealistic_layout.dart';

void main() {
  for (final name in [
    'Atmosphere',
    'Camera',
    'Terrain',
    'Tiles',
    'Globe',
    'Layers',
    'Offline',
  ]) {
    testWidgets('$name panels fit small screens and large text', (
      tester,
    ) async {
      final directory = Directory.systemTemp.createTempSync('scene-layout-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final page = switch (name) {
        'Atmosphere' => const AtmosphereLab(),
        'Camera' => const CameraLab(),
        'Terrain' => const TerrainLab(),
        'Tiles' => const Tiles3DLab(),
        'Globe' => const PlanetPage(),
        'Layers' => LayersLab(
          layoutFile: File('${directory.path}/layers.json'),
        ),
        _ => OfflineLab(directory: directory),
      };
      for (final size in [
        const Size(320, 568),
        const Size(844, 390),
        const Size(1440, 900),
      ]) {
        for (final scale in [1.0, 2.0]) {
          await tester.binding.setSurfaceSize(size);
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: page,
            ),
          );
          for (var i = 0; i < 8; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          expect(find.byType(PhotorealisticLayout), findsOneWidget);
          final canvas = find.byKey(const ValueKey('photorealistic-scene'));
          final original = tester.getRect(canvas);
          if (find.byKey(const ValueKey('controls-panel')).evaluate().isEmpty) {
            await tester.tap(find.byKey(const ValueKey('controls-toggle')));
            await tester.pump();
          }
          expect(tester.getRect(canvas), original);
          final scroll = find.byKey(const ValueKey('controls-scroll'));
          await tester.drag(scroll, const Offset(0, -1800));
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('info-toggle')));
          await tester.pump();
          expect(find.byKey(const ValueKey('info-panel')), findsOneWidget);
          expect(tester.getRect(canvas), original);
          await tester.tap(find.byKey(const ValueKey('panel-close')));
          await tester.pump();
          expect(
            tester.takeException(),
            isNull,
            reason: '$name $size text $scale',
          );
        }
      }
      final controllers = tester
          .widgetList<SceneView>(find.byType(SceneView))
          .map((view) => view.controller)
          .whereType<SceneController>()
          .toList();
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      Object? closingError;
      Future.wait(controllers.map((c) => c.whenDisposed)).then(
        (_) => closed = true,
        onError: (Object error) {
          closingError = error;
          closed = true;
        },
      );
      for (var i = 0; i < 500 && !closed; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(closed, isTrue);
      expect(closingError, isNull);
      await tester.binding.setSurfaceSize(null);
    });
  }
}
