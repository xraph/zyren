import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren_interaction/flutter_zyren_interaction.dart';
import '../../flutter_zyren/test/support/fakes.dart';

void main() {
  testWidgets(
    'semantics identity and action, keyboard focus, editable overlay lifecycle',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final scene = Scene();
      final object = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      final events = <String>[];
      final controller = SceneController(
        scene: scene,
        options: const EngineOptions(
          presentation: PresentationPolicy.readbackOnly,
        ),
        runtime: SceneRuntime(
          backendFactory: () async => TestRenderer(events),
          presenterFactory: () => TestPresenter('view', events),
          surfacePresenterFactory: null,
        ),
      );
      final router = SceneInteractionRouter(
        scene: scene,
        camera: () => controller.camera,
        viewport: () => (controller.input as ViewportInputSource).viewport,
      );
      controller.use(
        SceneInteractionPlugin(router, gestures: {SceneGesture.pointerDrag}),
      );
      router.register(object, (event) {
        if (event.phase == ObjectPointerPhase.down) event.capturePointer();
      });
      var activated = 0;
      router.focus.register(
        object,
        label: 'Pump',
        onActivate: () => activated++,
      );
      var showEditor = false;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Center(
                child: SizedBox(
                  width: 300,
                  height: 300,
                  child: SceneInteractionOverlay(
                    controller: controller,
                    router: router,
                    labels: [
                      SceneLabel(
                        id: 'label',
                        anchor: SceneAnchor(object),
                        child: const Text('Label'),
                      ),
                    ],
                    surfaces: [
                      if (showEditor)
                        SceneWidgetSurface(
                          id: 'editor',
                          anchor: SceneAnchor(object),
                          child: const Material(
                            child: TextField(
                              decoration: InputDecoration(labelText: 'Name'),
                            ),
                          ),
                        ),
                    ],
                    child: SceneView(controller: controller),
                  ),
                ),
              );
            },
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      final node = tester.getSemantics(
        find.byKey(ValueKey(('scene-semantics', object.id))),
      );
      final id = node.id;
      expect(node.getSemanticsData().identifier, 'scene-object-${object.id}');
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      tester.binding.performSemanticsAction(
        ui.SemanticsActionEvent(
          viewId: tester.view.viewId,
          nodeId: id,
          type: SemanticsAction.tap,
        ),
      );
      await tester.pump();
      expect(activated, 1);
      await tester.tap(find.byType(SceneView));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(router.focus.focusedObject, object);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(activated, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(router.focus.focusedObject, isNull);
      rebuild(() => showEditor = true);
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Pump 17');
      await tester.pump();
      expect(find.text('Pump 17'), findsOneWidget);
      expect(InputRouter.forSource(controller.input).blocked, isTrue);
      expect(router.focus.focusedObject, isNull);
      expect(
        tester
            .getSemantics(find.byKey(ValueKey(('scene-semantics', object.id))))
            .id,
        id,
      );
      scene.remove(object);
      await tester.pump();
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      expect(InputRouter.forSource(controller.input).blocked, isFalse);
      expect(
        find.byKey(ValueKey(('scene-semantics', object.id))),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      router.dispose();
      controller.dispose();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
  testWidgets('parent scroll arena loss cancels object capture', (
    tester,
  ) async {
    final events = <String>[];
    final scene = Scene()
      ..add(Mesh(BoxGeometry(width: 10, height: 10), UnlitMaterial()));
    final controller = SceneController(
      scene: scene,
      options: const EngineOptions(
        presentation: PresentationPolicy.readbackOnly,
      ),
      runtime: SceneRuntime(
        backendFactory: () async => TestRenderer(events),
        presenterFactory: () => TestPresenter('view', events),
        surfacePresenterFactory: null,
      ),
    );
    final router = SceneInteractionRouter(
      scene: scene,
      camera: () => controller.camera,
      viewport: () => (controller.input as ViewportInputSource).viewport,
    );
    final phases = <ObjectPointerPhase>[];
    router.register(scene.children.single, (e) {
      phases.add(e.phase);
      if (e.phase == ObjectPointerPhase.down) e.capturePointer();
    });
    controller.use(SceneInteractionPlugin(router));
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          controller: scroll,
          children: [
            SizedBox(height: 300, child: SceneView(controller: controller)),
            const SizedBox(height: 1200),
          ],
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final gesture = await tester.startGesture(const Offset(100, 150));
    await tester.pump();
    expect(router.capturedObjects, isNotEmpty);
    await gesture.moveBy(const Offset(0, -70));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(phases, contains(ObjectPointerPhase.cancel));
    expect(router.capturedObjects, isEmpty);
    expect(scroll.offset, greaterThan(0));
    await gesture.up();
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    controller.dispose();
    scroll.dispose();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.takeException(), isNull);
  });
}
