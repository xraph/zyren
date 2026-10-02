import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'support/backend_fake.dart';
import 'controller_test.dart' show frames, readback, runtime;

void main() {
  testWidgets(
    'trackpad scroll stays with its parent until the scene claims zoom',
    (tester) async {
      final controller = SceneController(
        options: readback,
        runtime: runtime(FakeBackend()),
      );
      final scroll = ScrollController();
      final events = <ScenePointerEvent>[];
      final subscription = controller.input.events.listen(events.add);
      addTearDown(subscription.cancel);
      await tester.pumpWidget(
        MaterialApp(
          home: ListView(
            controller: scroll,
            children: [
              SizedBox(height: 300, child: SceneView(controller: controller)),
              const SizedBox(height: 1000),
            ],
          ),
        ),
      );
      await frames(tester);
      final pointer = TestPointer(91, PointerDeviceKind.trackpad);
      const point = Offset(100, 100);
      Future<void> send(PointerEvent event) async {
        await tester.sendEventToBinding(event);
        await tester.pump();
      }

      await send(pointer.panZoomStart(point));
      await send(pointer.panZoomUpdate(point, pan: const Offset(0, -40)));
      await send(pointer.panZoomUpdate(point, pan: const Offset(0, -80)));
      await send(pointer.panZoomEnd());
      expect(scroll.offset, greaterThan(0));
      scroll.jumpTo(0);
      final interests = [
        for (final gesture in [
          SceneGesture.scroll,
          SceneGesture.pointerDrag,
          SceneGesture.scale,
        ])
          controller.input.registerGesture(gesture),
      ];
      await tester.pump();
      events.clear();
      await send(pointer.panZoomStart(point));
      await send(pointer.panZoomUpdate(point, pan: const Offset(0, -40)));
      await send(
        pointer.panZoomUpdate(point, pan: const Offset(0, -40), scale: 1.25),
      );
      await send(
        pointer.panZoomUpdate(point, pan: const Offset(0, -40), scale: 1.5625),
      );
      await send(
        pointer.panZoomUpdate(point, pan: const Offset(0, -40), scale: 1.5625),
      );
      await send(pointer.panZoomEnd());
      expect(scroll.offset, 0);
      final zoom = events
          .where((e) => e.phase == ScenePointerPhase.scroll)
          .toList();
      expect(zoom, hasLength(3));
      expect(zoom[0].delta.y, 40);
      expect(zoom[1].delta.y, closeTo(-44.6287102628, 1e-8));
      expect(zoom[2].delta.y, closeTo(zoom[1].delta.y, 1e-8));
      expect(zoom.every((e) => e.kind == ScenePointerKind.trackpad), isTrue);
      expect(
        events.where((e) => e.phase == ScenePointerPhase.scaleUpdate),
        isEmpty,
        reason: 'A trackpad update must not also enter the touch scale path.',
      );
      for (final interest in interests) {
        interest.dispose();
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
      scroll.dispose();
    },
  );

  testWidgets(
    'trackpad zoom uses local logical deltas and preserves its cursor anchor',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = SceneController(
        options: readback,
        runtime: runtime(FakeBackend()),
      );
      final events = <ScenePointerEvent>[];
      final interest = controller.input.registerGesture(SceneGesture.scroll);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: Transform.scale(
              scale: 1.25,
              child: SizedBox(
                width: 200,
                height: 150,
                child: SceneView(
                  controller: controller,
                  resolutionScale: .5,
                  onPointer: events.add,
                ),
              ),
            ),
          ),
        ),
      );
      await frames(tester);
      final box = tester.renderObject<RenderBox>(find.byType(SceneView));
      final point = box.localToGlobal(const Offset(120, 70));
      final pointer = TestPointer(92, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pointer.panZoomStart(point));
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(
          point,
          pan: const Offset(0, -25),
          timeStamp: const Duration(milliseconds: 16),
        ),
      );
      await tester.pump();
      final event = events.singleWhere(
        (e) => e.phase == ScenePointerPhase.scroll,
      );
      expect(event.point.x, closeTo(120, 1e-6));
      expect(event.point.y, closeTo(70, 1e-6));
      expect(event.delta.y, closeTo(20, 1e-6));
      expect(event.pointer, 92);
      expect(event.time, const Duration(milliseconds: 16));
      await tester.sendEventToBinding(pointer.panZoomEnd());
      interest.dispose();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
    },
  );

  testWidgets(
    'suspending trackpad input discards stale updates and a new pinch starts fresh',
    (tester) async {
      final controller = SceneController(
        options: readback,
        runtime: runtime(FakeBackend()),
      );
      final events = <ScenePointerEvent>[];
      final subscription = controller.input.events.listen(events.add);
      addTearDown(subscription.cancel);
      final interest = controller.input.registerGesture(SceneGesture.scroll);
      await tester.pumpWidget(
        MaterialApp(home: SceneView(controller: controller)),
      );
      await frames(tester);
      final pointer = TestPointer(93, PointerDeviceKind.trackpad);
      const point = Offset(100, 100);
      await tester.sendEventToBinding(pointer.panZoomStart(point));
      await tester.sendEventToBinding(pointer.panZoomUpdate(point, scale: 2));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(events.last.phase, ScenePointerPhase.cancel);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await frames(tester);
      events.clear();
      await tester.sendEventToBinding(pointer.panZoomUpdate(point, scale: 3));
      await tester.sendEventToBinding(pointer.panZoomEnd());
      await tester.pump();
      expect(events, isEmpty);
      await tester.sendEventToBinding(pointer.panZoomStart(point));
      await tester.sendEventToBinding(pointer.panZoomUpdate(point, scale: .5));
      await tester.pump();
      expect(events.single.delta.y, closeTo(138.629436112, 1e-8));
      interest.dispose();
      await tester.pump();
      expect(events.last.phase, ScenePointerPhase.cancel);
      final count = events.length;
      await tester.sendEventToBinding(pointer.panZoomUpdate(point, scale: .25));
      await tester.sendEventToBinding(pointer.panZoomEnd());
      await tester.pump();
      expect(events.length, count);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
    },
  );
}
