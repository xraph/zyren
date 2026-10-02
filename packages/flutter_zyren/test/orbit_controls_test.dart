import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'support/backend_fake.dart';
import 'controller_test.dart' show frames, readback, runtime;

Future<void> disposeController(
  WidgetTester tester,
  SceneController controller,
) async {
  controller.dispose();
  var disposed = false;
  controller.whenDisposed.then((_) => disposed = true);
  for (var i = 0; i < 20 && !disposed; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  expect(disposed, isTrue);
  await controller.whenDisposed;
}

void main() {
  testWidgets('trackpad pan and pinch change the view without orbiting', (
    tester,
  ) async {
    final controls = OrbitNavigation(damping: Duration.zero);
    final controller = SceneController(
      options: readback,
      runtime: runtime(FakeBackend()),
    )..use(controls);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 300,
            child: SceneView(controller: controller),
          ),
        ),
      ),
    );
    await frames(tester);
    final point = tester.getCenter(find.byType(SceneView));
    await tester.sendEventToBinding(
      PointerPanZoomStartEvent(pointer: 5, position: point),
    );
    await tester.sendEventToBinding(
      PointerPanZoomUpdateEvent(
        pointer: 5,
        position: point,
        pan: const Offset(40, 0),
        panDelta: const Offset(40, 0),
        scale: 2,
      ),
    );
    await tester.pump();
    expect(controller.camera.target.x, lessThan(0));
    final direction = controller.camera.position - controller.camera.target;
    expect(direction.x.abs(), lessThan(1e-9));
    expect(direction.y.abs(), lessThan(1e-9));
    expect(direction.z, closeTo(2.5, 1e-9));
    await tester.sendEventToBinding(
      PointerPanZoomEndEvent(pointer: 5, position: point),
    );
    await tester.pump();
    expect(controls.isInteracting, isFalse);
    await tester.pumpWidget(const SizedBox());
    await disposeController(tester, controller);
  });
  testWidgets('mouse buttons, wheel, cancellation and overlays stay local', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controls = OrbitNavigation();
    final controller = SceneController(
      options: readback,
      runtime: runtime(backend),
    )..use(controls);
    final focus = FocusNode();
    var overlayTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 300,
            child: Stack(
              children: [
                Positioned.fill(child: SceneView(controller: controller)),
                Positioned(
                  left: 0,
                  top: 0,
                  width: 120,
                  height: 40,
                  child: Material(
                    child: TextField(
                      focusNode: focus,
                      showCursor: false,
                      onTapOutside: (_) {},
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: TextButton(
                    onPressed: () => overlayTaps++,
                    child: const Text('Overlay action'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await frames(tester);
    await tester.tap(find.text('Overlay action'));
    await tester.pump();
    expect(overlayTaps, 1);
    expect(controller.camera.position, const Vec3(0, 0, 5));
    expect(controls.isInteracting, isFalse);
    await tester.enterText(find.byType(TextField), 'local focus');
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    final origin = tester.getTopLeft(find.byType(SceneView));
    final before = controller.camera.position;
    final drag = await tester.startGesture(
      origin + const Offset(150, 180),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(45, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await drag.moveBy(const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await drag.up();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 20),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(controller.camera.position, isNot(before));
    expect(controls.isSettling, isFalse);
    expect(focus.hasFocus, isTrue);
    final stable = backend.submissions.length;
    await tester.pump(const Duration(seconds: 1));
    expect(backend.submissions.length, stable);
    controls.reset();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 20),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    final pan = await tester.startGesture(
      origin + const Offset(150, 180),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await pan.moveBy(const Offset(45, 0));
    await tester.pump();
    await pan.moveBy(const Offset(20, 0));
    await tester.pump();
    await pan.up();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 20),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(controller.camera.target.x, lessThan(0));
    expect(
      controller.camera.position.distanceTo(controller.camera.target),
      closeTo(5, 1e-8),
    );
    final distance = controller.camera.position.distanceTo(
      controller.camera.target,
    );
    final middle = await tester.startGesture(
      origin + const Offset(150, 180),
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await middle.moveBy(const Offset(0, 45));
    await tester.pump();
    await middle.moveBy(const Offset(0, 20));
    await tester.pump();
    await middle.up();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 20),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(
      controller.camera.position.distanceTo(controller.camera.target),
      greaterThan(distance),
    );
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: origin + const Offset(100, 180),
        scrollDelta: const Offset(0, -100),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 20),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(controls.isSettling, isFalse);
    final cancel = await tester.startGesture(origin + const Offset(150, 180));
    await cancel.moveBy(const Offset(40, 20));
    await tester.pump();
    await cancel.cancel();
    await tester.pump();
    final stopped = controller.camera.position;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.camera.position, stopped);
    expect(controls.isInteracting, isFalse);
    expect(controls.isSettling, isFalse);
    await tester.pumpWidget(const SizedBox());
    await disposeController(tester, controller);
    focus.dispose();
  });
  testWidgets(
    'disabled orbit yields to scroll parent and wheel interest returns when enabled',
    (tester) async {
      final controls = OrbitNavigation(enabled: false, damping: Duration.zero);
      final controller = SceneController(
        options: readback,
        runtime: runtime(FakeBackend()),
      )..use(controls);
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: ListView(
            controller: scroll,
            children: [
              SizedBox(height: 300, child: SceneView(controller: controller)),
              const SizedBox(height: 1500),
            ],
          ),
        ),
      );
      await frames(tester);
      final origin = tester.getTopLeft(find.byType(SceneView));
      await tester.dragFrom(
        origin + const Offset(100, 200),
        const Offset(0, -100),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 20),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(scroll.offset, greaterThan(0));
      expect(controller.camera.position, const Vec3(0, 0, 5));
      scroll.jumpTo(0);
      controls.enabled = true;
      await tester.pump();
      final verticalDrag = await tester.startGesture(
        origin + const Offset(100, 200),
      );
      await verticalDrag.moveBy(const Offset(0, -20));
      await tester.pump();
      await verticalDrag.moveBy(const Offset(0, -20));
      await verticalDrag.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      expect(controller.camera.position, const Vec3(0, 0, 5));
      expect(controls.isInteracting, isFalse);
      scroll.jumpTo(0);
      await tester.pump();
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: origin + const Offset(100, 100),
          scrollDelta: const Offset(0, 100),
        ),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 20),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(scroll.offset, 0);
      expect(controller.camera.position.z, greaterThan(5));
      controls.enabled = false;
      await tester.pump();
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: origin + const Offset(100, 100),
          scrollDelta: const Offset(0, 100),
        ),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 20),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(scroll.offset, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      await disposeController(tester, controller);
      scroll.dispose();
    },
  );
  testWidgets(
    'orbit motion ignores render resolution and suspends on lifecycle loss',
    (tester) async {
      Vec3? baseline;
      for (final scale in [.5, 1.0]) {
        tester.view.devicePixelRatio = 1.5;
        final controls = OrbitNavigation(damping: Duration.zero);
        final controller = SceneController(
          options: readback,
          runtime: runtime(FakeBackend()..maxDimension = 1000),
        )..use(controls);
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: SceneView(
                  controller: controller,
                  resolutionScale: scale,
                ),
              ),
            ),
          ),
        );
        await frames(tester);
        final origin = tester.getTopLeft(find.byType(SceneView));
        final g = await tester.startGesture(origin + const Offset(80, 100));
        await g.moveBy(const Offset(40, 0));
        await tester.pump();
        await g.moveBy(const Offset(10, 0));
        await tester.pump();
        if (baseline == null) {
          baseline = controller.camera.position;
        } else {
          expect(
            controller.camera.position.distanceTo(baseline),
            lessThan(1e-9),
          );
        }
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(controls.isInteracting, isFalse);
        final stopped = controller.camera.position;
        await g.moveBy(const Offset(20, 0));
        await g.up();
        await tester.pump();
        expect(controller.camera.position, stopped);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        await disposeController(tester, controller);
        tester.view.resetDevicePixelRatio();
      }
    },
  );
}
