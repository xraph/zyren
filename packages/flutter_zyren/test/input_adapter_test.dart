import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'support/backend_fake.dart';
import 'controller_test.dart' show frames, readback, runtime;

void main() {
  testWidgets('claimed drags preserve taps without selecting after gestures', (
    tester,
  ) async {
    final controller = SceneController(
      options: readback,
      runtime: runtime(FakeBackend()),
    );
    final events = <ScenePointerEvent>[];
    final drag = controller.input.registerGesture(SceneGesture.pointerDrag);
    final tap = controller.input.registerGesture(SceneGesture.tap);
    await tester.pumpWidget(
      MaterialApp(
        home: SceneView(controller: controller, onPointer: events.add),
      ),
    );
    await frames(tester);
    const point = Offset(100, 100);
    int taps() => events.where((e) => e.phase == ScenePointerPhase.tap).length;
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      final click = await tester.startGesture(point, kind: kind);
      await click.up();
    }
    expect(taps(), 2);
    final moved = await tester.startGesture(point);
    await moved.moveBy(const Offset(50, 0));
    await moved.moveTo(point);
    await moved.up();
    final first = await tester.startGesture(point, pointer: 21);
    final second = await tester.startGesture(
      point + const Offset(20, 0),
      pointer: 22,
    );
    await second.up();
    await first.up();
    final cancelled = await tester.startGesture(point);
    await cancelled.cancel();
    final secondary = await tester.startGesture(
      point,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await secondary.up();
    expect(taps(), 2);
    // Returning to Flutter's recognizer must produce exactly one tap too.
    drag.dispose();
    await tester.pump();
    await tester.tapAt(point);
    expect(taps(), 3);
    tap.dispose();
    controller.dispose();
    await frames(tester);
    await controller.whenDisposed;
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'registered pinch wins its arena and overlay text keeps keyboard focus',
    (tester) async {
      final backend = FakeBackend();
      final controller = SceneController(
        options: readback,
        runtime: runtime(backend),
      );
      final events = <ScenePointerEvent>[];
      final interest = controller.input.registerGesture(SceneGesture.scale);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 300,
              height: 300,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: SceneView(
                      controller: controller,
                      onPointer: events.add,
                    ),
                  ),
                  const Positioned(
                    left: 0,
                    top: 0,
                    width: 150,
                    height: 50,
                    child: Material(child: TextField()),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await frames(tester);
      await tester.enterText(find.byType(TextField), 'Camera');
      await tester.pump();
      expect(find.text('Camera'), findsOneWidget);
      final origin = tester.getTopLeft(find.byType(SceneView));
      final first = await tester.startGesture(
        origin + const Offset(100, 160),
        pointer: 1,
      );
      final second = await tester.startGesture(
        origin + const Offset(200, 160),
        pointer: 2,
      );
      await first.moveTo(origin + const Offset(70, 160));
      await second.moveTo(origin + const Offset(230, 160));
      await tester.pump();
      await first.moveTo(origin + const Offset(60, 160));
      await tester.pump();
      expect(
        events
            .where((e) => e.phase == ScenePointerPhase.scaleUpdate)
            .any((e) => e.scale > 1),
        isTrue,
      );
      await first.up();
      await second.up();
      interest.dispose();
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('logical point maps to NDC once', () {
    expect(
      const ViewportPoint(25, 75).toNdc(logicalWidth: 100, logicalHeight: 100),
      const Vec3(-.5, -.5, 0),
    );
    expect(
      () => const ViewportPoint(0, 0).toNdc(logicalWidth: 0, logicalHeight: 1),
      throwsArgumentError,
    );
  });
  for (final scale in [.5, 1.0]) {
    testWidgets(
      'transformed logical input and overlay at DPR 1.5, scale $scale',
      (tester) async {
        tester.view.devicePixelRatio = 1.5;
        addTearDown(tester.view.resetDevicePixelRatio);
        final backend = FakeBackend()..maxDimension = 1000;
        final controller = SceneController(
          options: readback,
          runtime: runtime(backend),
        );
        final events = <ScenePointerEvent>[];
        var taps = 0;
        const viewportKey = ValueKey('viewport');
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: Transform.scale(
                scale: 1.25,
                child: SizedBox(
                  width: 200,
                  height: 100,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: SceneView(
                          key: viewportKey,
                          controller: controller,
                          resolutionScale: scale,
                          onPointer: events.add,
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: 0,
                        width: 80,
                        height: 40,
                        child: TextButton(
                          onPressed: () => taps++,
                          child: const Text('Overlay'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await frames(tester);
        final box = tester.renderObject<RenderBox>(find.byKey(viewportKey));
        await tester.tapAt(box.localToGlobal(const Offset(150, 70)));
        await tester.pump();
        final down = events.firstWhere(
          (e) => e.phase == ScenePointerPhase.down,
        );
        expect(down.point.x, closeTo(150, 1e-6));
        expect(down.point.y, closeTo(70, 1e-6));
        final metrics = (controller.input as ViewportInputSource).viewport;
        expect(metrics.width, 200);
        expect(metrics.height, 100);
        expect(metrics.devicePixelRatio, 1.5);
        expect(
          backend.submissions.first.size.width,
          (200 * 1.5 * scale).round(),
        );
        final count = events.length;
        await tester.tap(find.text('Overlay'));
        await tester.pump();
        expect(taps, 1);
        expect(events.length, count);
        controller.dispose();
        await frames(tester);
        await controller.whenDisposed;
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'key interests require scene focus and cancel on focus loss or removal',
    (tester) async {
      final controller = SceneController(
        options: readback,
        runtime: runtime(FakeBackend()),
      );
      final keyboard = controller.input as KeyboardInputSource;
      final events = <SceneKeyEvent>[];
      final subscription = keyboard.keyEvents.listen(events.add);
      addTearDown(subscription.cancel);
      final interest = keyboard.registerKeys({
        SceneKey.arrowLeft,
        SceneKey.arrowRight,
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              const Material(child: TextField()),
              SizedBox(
                width: 300,
                height: 200,
                child: SceneView(controller: controller),
              ),
            ],
          ),
        ),
      );
      await frames(tester);
      await tester.enterText(find.byType(TextField), 'Text keeps arrows');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(events, isEmpty);
      await tester.tap(find.byType(SceneView));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(events.map((e) => e.phase), [
        SceneKeyPhase.down,
        SceneKeyPhase.repeat,
      ]);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(events.last.phase, SceneKeyPhase.cancel);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.tap(find.byType(SceneView));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      interest.dispose();
      await tester.pump();
      expect(events.last.phase, SceneKeyPhase.cancel);
      final count = events.length;
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(events.length, count);
      await tester.pumpWidget(const SizedBox());
      expect(
        (controller.input as ViewportInputSource).viewport.isUsable,
        isFalse,
      );
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
    },
  );
  testWidgets('claimed raw pointer drag owns its arena and cancels on detach', (
    tester,
  ) async {
    final controller = SceneController(
      options: readback,
      runtime: runtime(FakeBackend()),
    );
    final scroll = ScrollController();
    final events = <ScenePointerEvent>[];
    final subscription = controller.input.events.listen(events.add);
    addTearDown(subscription.cancel);
    final interest = controller.input.registerGesture(SceneGesture.pointerDrag);
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
    final gesture = await tester.startGesture(const Offset(80, 100));
    await gesture.moveBy(const Offset(0, -70));
    await tester.pump();
    expect(scroll.offset, 0);
    expect(events.any((e) => e.phase == ScenePointerPhase.move), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(events.last.phase, ScenePointerPhase.cancel);
    await gesture.up();
    interest.dispose();
    controller.dispose();
    await frames(tester);
    await controller.whenDisposed;
    scroll.dispose();
  });
  testWidgets(
    'unclaimed scroll stays with Flutter and registered wheel interest owns it',
    (tester) async {
      final backend = FakeBackend();
      final controller = SceneController(
        options: readback,
        runtime: runtime(backend),
      );
      final scroll = ScrollController();
      final events = <ScenePointerEvent>[];
      final subscription = controller.input.events.listen(events.add);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            height: 200,
            child: ListView(
              controller: scroll,
              children: [
                SizedBox(height: 300, child: SceneView(controller: controller)),
                const SizedBox(height: 1000),
              ],
            ),
          ),
        ),
      );
      await frames(tester);
      final point =
          tester.getTopLeft(find.byType(SceneView)) + const Offset(30, 30);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: point,
          scrollDelta: const Offset(0, 30),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
      expect(scroll.offset, greaterThan(0));
      scroll.jumpTo(0);
      await tester.pump();
      final interest = controller.input.registerGesture(SceneGesture.scroll);
      await tester.pump();
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: point,
          scrollDelta: const Offset(0, 30),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pump();
      expect(scroll.offset, 0);
      expect(
        events.where((e) => e.phase == ScenePointerPhase.scroll),
        hasLength(1),
      );
      interest.dispose();
      addTearDown(subscription.cancel);
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );
}
