import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';

Future<void> exerciseWorkbenchTimeline(WidgetTester tester) async {
  final status = find.byKey(const ValueKey('timeline-event'));
  final slider = find.byKey(const ValueKey('timeline'));
  bool shows(String text) =>
      status.evaluate().isNotEmpty && tester.widget<Text>(status).data == text;
  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 240; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      expect(tester.takeException(), isNull);
      if (condition()) return;
    }
    fail('Playback did not reach the expected marker.');
  }

  await until(() => tester.widget<Slider>(slider).onChanged != null);
  final controller = tester
      .widget<SceneView>(find.byType(SceneView))
      .controller!;
  final parts = controller.scene.children
      .singleWhere((node) => node.name == 'Pump assembly')
      .children;
  final cover = parts.singleWhere((node) => node.name == 'Cover');
  final housing = parts.singleWhere((node) => node.name == 'Housing');
  final mix = find.byKey(const ValueKey('timeline-mix'));
  for (final (time, weight) in [
    (0.0, 0),
    (.25, 50),
    (.5, 100),
    (.75, 50),
    (1.0, 0),
    (.5, 100),
  ]) {
    tester.widget<Slider>(slider).onChanged!(time);
    await tester.pump();
    expect(tester.widget<Text>(mix).data, 'Lift $weight%');
    expect(cover.position.x, closeTo(.95 + 1.45 * time, 1e-10));
    expect(cover.position.y, closeTo(1.1 * weight / 100, 1e-10));
    expect(housing.position.y, 0);
    if (weight == 0) expect(cover.quaternion, Quat.identity);
    if (weight == 100) {
      expect(
        cover.quaternion.rotate(const Vec3(1, 0, 0)).y,
        closeTo(.7071067811865475, 1e-10),
      );
    }
    expect(status, findsNothing);
  }
  await tester.tap(find.byTooltip('Reset pose'));
  await tester.pump();
  expect(status, findsNothing);
  await tester.tap(find.byTooltip('Play'));
  await until(() => shows('Assembled'));
  await tester.tap(find.byTooltip('Pause'));
  await tester.pump();
  final paused = tester.widget<Slider>(slider).value;
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(tester.widget<Slider>(slider).value, paused);
  expect(shows('Assembled'), isTrue);
  await tester.tap(find.byTooltip('Play'));
  await until(() => shows('Separating'));
  await tester.tap(find.byTooltip('Pause'));
  await tester.pump();
  tester.widget<Slider>(slider).onChanged!(.75);
  await tester.pump();
  expect(status, findsNothing);
  expect(tester.widget<Slider>(slider).value, .75);
  await tester.tap(find.byTooltip('Play'));
  await until(() => shows('Exploded'));
  expect(find.byTooltip('Play'), findsOneWidget);
  expect(tester.widget<Slider>(slider).value, 1);
  await tester.tap(find.byTooltip('Play'));
  await until(() => shows('Assembled'));
  await tester.tap(find.byTooltip('Pause'));
  await tester.pump();
  await tester.tap(find.byTooltip('Reset pose'));
  await tester.pump();
  expect(status, findsNothing);
  expect(tester.widget<Slider>(slider).value, 0);
  expect(tester.widget<Text>(mix).data, 'Lift 0%');
  expect(cover.position.y, 0);
  expect(tester.takeException(), isNull);
}
