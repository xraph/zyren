import 'dart:io';
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
      scenes.map((d) => 'ocean.${d.id}'),
    );
    expect(geospatialDemos.where((d) => d.requiresProvider).map((d) => d.id), [
      'photorealistic',
      'clouds',
    ]);
  });
  for (final size in [const Size(1440, 900), const Size(390, 844)]) {
    testWidgets('launcher opens one scene and returns at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var builds = 0;
      await tester.pumpWidget(
        PlanetApp(
          home: GeospatialSceneLauncher(
            sceneBuilder: (demo) {
              builds++;
              return Center(child: Text('Scene ${demo.id}'));
            },
          ),
        ),
      );
      expect(builds, 0);
      expect(find.text('Photorealistic Earth'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Ocean'));
      await tester.pumpAndSettle();
      expect(find.text('Photorealistic Earth'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('scene-ocean.calm')));
      await tester.pumpAndSettle();
      expect(builds, 1);
      expect(find.text('Scene ocean.calm'), findsOneWidget);
      await tester.tap(find.byTooltip('All scenes'));
      await tester.pumpAndSettle();
      expect(find.text('Geospatial scenes'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
