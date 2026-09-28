import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'controller_test.dart' show frames, readback, runtime;
import 'support/backend_fake.dart';

Future<(SceneController, List<ScenePointerEvent>, Registration)> mount(
  WidgetTester tester,
) async {
  final controller = SceneController(
    options: readback,
    runtime: runtime(FakeBackend()),
  );
  final events = <ScenePointerEvent>[];
  final subscription = controller.input.events.listen(events.add);
  addTearDown(subscription.cancel);
  final interest = controller.input.registerGesture(SceneGesture.scroll);
  await tester.pumpWidget(
    MaterialApp(
      home: Column(
        children: [
          TextButton(onPressed: () {}, child: const Text('Reset view')),
          Expanded(child: SceneView(controller: controller)),
        ],
      ),
    ),
  );
  await frames(tester);
  return (controller, events, interest);
}

Future<void> dispose(WidgetTester tester, SceneController controller) async {
  controller.dispose();
  await frames(tester);
  await controller.whenDisposed;
  await tester.pumpWidget(const SizedBox());
}

Future<void> flick(
  WidgetTester tester, {
  double pixels = 24,
  int interval = 16,
  int releaseDelay = 0,
}) async {
  final pointer = TestPointer(81, PointerDeviceKind.trackpad);
  final point = tester.getCenter(find.byType(SceneView));
  await tester.sendEventToBinding(pointer.panZoomStart(point));
  for (var step = 1; step <= 4; step++) {
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(
        point,
        pan: Offset(0, -pixels * step),
        timeStamp: Duration(milliseconds: interval * step),
      ),
    );
    await tester.pump(Duration(milliseconds: interval));
  }
  await tester.pump(Duration(milliseconds: releaseDelay));
  await tester.sendEventToBinding(
    pointer.panZoomEnd(
      timeStamp: Duration(milliseconds: interval * 4 + releaseDelay),
    ),
  );
  await tester.pump();
}

List<double> deltas(List<ScenePointerEvent> events) => [
  for (final event in events)
    if (event.phase == ScenePointerPhase.scroll) event.delta.y,
];

void main() {
  testWidgets('trackpad speed controls a decaying zoom tail after release', (
    tester,
  ) async {
    final (controller, events, _) = await mount(tester);
    final travel = <double>[];
    for (final interval in [32, 8]) {
      events.clear();
      await flick(tester, interval: interval);
      expect(deltas(events).reduce((a, b) => a + b), closeTo(96, 1e-8));
      events.clear();
      for (var frame = 0; frame < 90; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final tail = deltas(events);
      expect(tail.length, greaterThan(10));
      expect(tail.every((delta) => delta > 0), isTrue);
      for (var i = 1; i < tail.length; i++) {
        expect(tail[i], lessThan(tail[i - 1]));
      }
      travel.add(tail.reduce((a, b) => a + b));
      final count = events.length;
      await tester.pump(const Duration(seconds: 2));
      expect(events.length, count, reason: 'A completed coast must stay idle.');
    }
    expect(travel[1], greaterThan(travel[0] * 3));
    expect(travel[1], lessThanOrEqualTo(400));
    await dispose(tester, controller);
  });

  testWidgets('a pause before finger lift does not launch another zoom', (
    tester,
  ) async {
    final (controller, events, _) = await mount(tester);
    await flick(tester, releaseDelay: 150);
    events.clear();
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(events, isEmpty);
    await dispose(tester, controller);
  });

  testWidgets('a reverse gesture replaces remaining trackpad momentum', (
    tester,
  ) async {
    final (controller, events, _) = await mount(tester);
    await flick(tester);
    await tester.pump(const Duration(milliseconds: 32));
    events.clear();
    await flick(tester, pixels: -24);
    expect(events.first.phase, ScenePointerPhase.cancel);
    events.clear();
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(deltas(events), isNotEmpty);
    expect(deltas(events).every((delta) => delta < 0), isTrue);
    await dispose(tester, controller);
  });

  for (final interrupt in [
    'suspend',
    'unregister',
    'touch',
    'outside',
    'inertiaCancel',
    'detach',
  ]) {
    testWidgets('$interrupt stops released trackpad momentum', (tester) async {
      final (controller, events, interest) = await mount(tester);
      await flick(tester);
      events.clear();
      switch (interrupt) {
        case 'suspend':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
        case 'unregister':
          interest.dispose();
        case 'touch':
          final touch = await tester.startGesture(
            tester.getCenter(find.byType(SceneView)),
          );
          await touch.up();
        case 'outside':
          await tester.tap(find.text('Reset view'));
        case 'inertiaCancel':
          await tester.sendEventToBinding(
            const PointerScrollInertiaCancelEvent(position: Offset(100, 100)),
          );
        case 'detach':
          await tester.pumpWidget(const SizedBox());
      }
      await tester.pump();
      expect(events.any((e) => e.phase == ScenePointerPhase.cancel), isTrue);
      events.clear();
      for (var frame = 0; frame < 60; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(deltas(events), isEmpty);
      if (interrupt == 'suspend') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await frames(tester);
      }
      await dispose(tester, controller);
    });
  }

  testWidgets('trackpad momentum distance is stable at 30, 60 and 120 Hz', (
    tester,
  ) async {
    final (controller, events, _) = await mount(tester);
    final travel = <double>[];
    for (final hz in [30, 60, 120]) {
      await flick(tester);
      events.clear();
      for (var frame = 0; frame < hz * 2; frame++) {
        await tester.pump(Duration(microseconds: (1000000 / hz).round()));
      }
      travel.add(deltas(events).fold(0, (a, b) => a + b));
    }
    expect(travel.first, greaterThan(100));
    for (final distance in travel.skip(1)) {
      expect(distance, closeTo(travel.first, .25));
    }
    await dispose(tester, controller);
  });
}
