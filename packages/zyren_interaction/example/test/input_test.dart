import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_interaction_example/main.dart';
import '../../../flutter_zyren/test/support/fakes.dart';

void main() {
  testWidgets(
    'public SceneView input hovers, captures, drags and releases tools',
    (tester) async {
      final key = GlobalKey<InteractionDemoState>();
      final events = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: InteractionDemo(
            key: key,
            runtime: SceneRuntime(
              backendFactory: () async => TestRenderer(events),
              presenterFactory: () => TestPresenter('viewport', events),
              surfacePresenterFactory: null,
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      final state = key.currentState!;
      expect(state.controller.status.value, isA<SceneReady>());
      final view = find.byType(SceneView);
      final extent = tester.getSize(view), origin = tester.getTopLeft(view);
      final object = state.objects.first;
      final ndc = state.controller.camera.projectPoint(
        object.position,
        extent.aspectRatio,
      );
      final point =
          origin +
          Offset(
            (ndc.x + 1) * extent.width / 2,
            (1 - ndc.y) * extent.height / 2,
          );
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 17,
      );
      await mouse.addPointer(location: point);
      await tester.pump();
      await mouse.moveTo(point + const Offset(1, 0));
      await tester.pump();
      expect(state.hovered, 'Orange');
      await mouse.down(point);
      await tester.pump();
      expect(state.tools.selected, same(object));
      expect(state.interaction.capturedObjects, isNotEmpty);
      final before = object.position;
      await mouse.moveBy(const Offset(45, 15));
      await tester.pump();
      expect(object.position, isNot(before));
      await mouse.up();
      await tester.pump();
      expect(state.interaction.capturedObjects, isEmpty);
      expect(state.tools.canUndo, isTrue);
      state.tools.undo();
      expect(object.position, before);
      await mouse.removePointer();
      await tester.tap(find.text('Inspector'));
      await tester.pumpAndSettle();
      expect(find.text('Scene inspector'), findsOneWidget);
      expect(find.textContaining('Orange'), findsWidgets);
      final context = await state.agentHost.registry.call(
        providerId: 'zyren.viewport',
        instanceId: 'main',
        tool: 'context',
      );
      expect((context.data['hostState'] as Map)['pointerBlockedByUi'], isTrue);
      Navigator.of(tester.element(find.text('Scene inspector'))).pop();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tester.takeException(), isNull);
    },
  );
}
