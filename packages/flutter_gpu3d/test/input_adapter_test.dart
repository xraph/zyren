import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'support/backend_fake.dart';
import 'controller_test.dart' show frames, readback, runtime;

void main() {
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
      expect(controller.input, isA<ViewportInputSource>());
      expect((controller.input as ViewportInputSource).logicalWidth, 300);
      expect((controller.input as ViewportInputSource).logicalHeight, 300);
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
      expect(
        events
            .where((e) => e.phase == ScenePointerPhase.scaleUpdate)
            .any(
              (e) => e.pointerCount == 2 && e.kind == ScenePointerKind.touch,
            ),
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
