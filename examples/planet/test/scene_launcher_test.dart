import 'dart:io';
import 'package:planet/photorealistic_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planet/main.dart';
import 'package:planet/scene_launcher.dart';
import 'package:planet/ocean/scenes/definition.dart';

void main() {
  test('launcher contains every saved ocean scene once', () {
    final scenes = OceanLabSceneDefinition.decode(
      File('assets/ocean/scenes.json').readAsStringSync(),
    );
    expect(
      geospatialDemos.map((d) => d.id).toSet().length,
      geospatialDemos.length,
    );
    expect(
      geospatialDemos.where((d) => d.category == 'Ocean').map((d) => d.id),
      ['ocean.earth', ...scenes.map((d) => 'ocean.${d.id}')],
    );
    expect(geospatialDemos.where((d) => d.requiresProvider).map((d) => d.id), [
      'photorealistic',
      'clouds',
    ]);
  });
  for (final (size, scale) in [
    for (final size in [
      const Size(1440, 900),
      const Size(390, 844),
      const Size(844, 390),
      const Size(320, 320),
    ])
      for (final scale in [1.0, 2.0]) (size, scale),
  ]) {
    testWidgets('launcher opens one scene and returns at $size text $scale', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      var builds = 0;
      await tester.pumpWidget(
        PlanetApp(
          home: GeospatialSceneLauncher(
            sceneBuilder: (demo) {
              builds++;
              return Scaffold(
                body: PhotorealisticLayout(
                  title: demo.title,
                  scene: Center(child: Text('Scene ${demo.id}')),
                  controls: const Text('Controls'),
                  info: const Text('Info'),
                ),
              );
            },
          ),
        ),
      );
      expect(builds, 0);
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Ocean'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Ocean'));
      await tester.pumpAndSettle();
      expect(find.text('Photorealistic Earth'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('scene-ocean.calm')),
        150,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scene-ocean.calm')));
      await tester.pumpAndSettle();
      expect(builds, 1);
      expect(find.text('Scene ocean.calm'), findsOneWidget);
      await tester.tap(find.byTooltip('All scenes'));
      await tester.pumpAndSettle();
      expect(find.byType(GeospatialSceneLauncher), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Geospatial scenes'), -200);
      await tester.pumpAndSettle();
      expect(find.text('Geospatial scenes'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
