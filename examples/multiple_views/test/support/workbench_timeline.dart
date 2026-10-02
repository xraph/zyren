import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
  expect(tester.takeException(), isNull);
}
