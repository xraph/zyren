import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import '../../../packages/zyren_studio/test/support/renderer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio_example/fixture.dart';
import 'package:zyren_studio_example/studio_properties.dart';
import 'package:zyren_studio_example/studio_theme.dart';

void main() {
  testWidgets(
    'rotation fields use degrees, save quaternions and support undo',
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
      addTearDown(() => tester.runAsync(engine!.dispose));
      final object = scene.objects['block']!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 280,
              child: StudioProperties(
                object: object,
                onRotation: (q) => scene.edit(
                  () => scene.tools.transform(object, rotation: q),
                ),
              ),
            ),
          ),
        ),
      );
      final y = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.labelText == 'Rotation (degrees) Y',
      );
      await tester.ensureVisible(y);
      await tester.enterText(y, '90');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(
        object.quaternion
            .rotate(const Vec3(1, 0, 0))
            .distanceTo(const Vec3(0, 0, -1)),
        lessThan(1e-9),
      );
      expect(
        scene.capture().expandedNodes['block']!.rotation,
        object.quaternion,
      );
      expect(scene.undo(), isTrue);
      expect(object.quaternion, Quat.identity);
      expect(tester.takeException(), isNull);
    },
  );
  test('Euler display round trips combined rotations and singular cases', () {
    for (final value in [
      const Vec3(20, 35, -15),
      const Vec3(10, 90, 20),
      const Vec3(10, -90, 20),
    ]) {
      final q = rotationFromDegrees(value),
          round = rotationFromDegrees(
            rotationDegrees(rotationFromDegrees(value)),
          );
      expect(
        round
            .rotate(const Vec3(1, 2, 3))
            .distanceTo(q.rotate(const Vec3(1, 2, 3))),
        lessThan(1e-6),
      );
    }
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'compact properties edit with undo and reject invalid input in $brightness',
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
        addTearDown(() => tester.runAsync(engine!.dispose));
        final object = scene.objects['block']!;
        await tester.pumpWidget(
          MaterialApp(
            theme: studioTheme(brightness),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 260,
                  height: 500,
                  child: StudioProperties(
                    object: object,
                    onPosition: (value) => scene.edit(
                      () => scene.tools.transform(object, position: value),
                    ),
                    onScale: (value) => scene.edit(
                      () => scene.tools.transform(object, scale: value),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final x = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Position X',
        );
        await tester.enterText(x, '1.75');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(scene.capture().expandedNodes['block']!.position.x, 1.75);
        expect(scene.undo(), isTrue);
        expect(scene.capture().expandedNodes['block']!.position.x, 0);
        await tester.enterText(x, 'NaN');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(find.text('Number'), findsOneWidget);
        expect(scene.capture().expandedNodes['block']!.position.x, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
