import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren_studio/flutter_zyren_studio.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio/commands.dart';
import 'package:zyren_studio_example/fixture.dart';
import 'package:zyren_studio_example/geospatial_placement.dart';
import 'package:zyren_studio_example/studio_properties.dart';
import 'package:zyren_studio_example/studio_theme.dart';
import '../../../packages/zyren_studio/test/support/renderer.dart';

void main() {
  testWidgets(
    'geodetic placement converts parent transforms, validates, undoes and detaches',
    (tester) async {
      final scene = StudioScene(starterScene());
      final engine = await tester.runAsync(
        () => SceneEngine.create(
          scene: scene.scene,
          camera: scene.camera,
          rendererFactory: () async => TestRenderer([]),
          plugins: [scene.tools],
        ),
      );
      final commands = StudioCommands(
        scene: scene,
        sessionId: 'placement',
        isAllowed: (_) => true,
        isAvailable: () => true,
      );
      final agents = AgentRegistry(grantedScopes: const {});
      final host = StudioEditorHostController(
        services: StudioEditorServices(
          scene: scene,
          commands: commands,
          agents: agents,
          isAvailable: () => true,
          viewportSnapshot: () => {},
          capabilities: () => {},
          applyDocument: scene.apply,
        ),
      );
      addTearDown(
        () => tester.runAsync(() async {
          host.dispose();
          commands.dispose();
          agents.dispose();
          await engine!.dispose();
        }),
      );
      final block = scene.objects['block']!;
      scene.objects['assembly']!.position = const Vec3(20, 4, -12);
      scene.tools.select(block);
      final lease = host.register(
        geospatialPlacementContribution(
          origin: Geodetic.degrees(-87.63, 41.88, 180),
        ),
      );
      final binding = host.placementForSelection!;
      final display = binding.toDisplay(block.position);
      expect(
        binding.toLocal(display).distanceTo(block.position),
        lessThan(.00001),
      );
      expect(display.z, closeTo(184, .01));
      await tester.pumpWidget(
        MaterialApp(
          theme: studioTheme(Brightness.light),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 280,
                height: 600,
                child: AnimatedBuilder(
                  animation: host,
                  builder: (_, _) => StudioProperties(
                    object: block,
                    placement: host.placementForSelection,
                    onPosition: (position) {
                      scene.edit(
                        () => scene.tools.transform(block, position: position),
                      );
                      host.refresh();
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      await tester.enterText(
        field('World placement Longitude'),
        '${display.x + .001}',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(block.position.x, greaterThan(50));
      expect(scene.capture().expandedNodes['block']!.position, block.position);
      expect(scene.undo(), isTrue);
      host.refresh();
      await tester.pump();
      expect(block.position, Vec3.zero);
      await tester.enterText(field('World placement Latitude'), '91');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Out of range'), findsOneWidget);
      expect(block.position, Vec3.zero);
      lease.dispose();
      await tester.pump();
      expect(host.placementIds, isEmpty);
      expect(field('Position X'), findsOneWidget);
      expect(() => binding.toLocal(display), throwsStateError);
      expect(tester.takeException(), isNull);
    },
  );
}
