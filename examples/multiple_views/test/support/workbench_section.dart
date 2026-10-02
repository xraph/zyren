import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';

Future<void> exerciseWorkbenchSections(
  WidgetTester tester,
  SceneController controller,
) async {
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Iterable<Object3D> descendants(Object3D node) sync* {
    for (final child in node.children) {
      yield child;
      yield* descendants(child);
    }
  }

  Iterable<Object3D> capsInScene() =>
      descendants(controller.scene).where((node) => node.name == 'Section cap');
  final caps = find.byKey(const ValueKey('section-caps'));
  final overlay = find.byKey(const ValueKey('gizmo-overlay'));
  await tester.tap(overlay);
  await settle();
  final overlayEnabled = tester.widget<IconButton>(overlay).isSelected!;
  final handles = descendants(controller.scene).whereType<Mesh>().where(
    (mesh) => mesh.name?.startsWith('translate ') ?? false,
  );
  expect(handles, isNotEmpty);
  expect(
    handles.every((mesh) => mesh.material.depthTest == !overlayEnabled),
    isTrue,
  );
  await tester.tap(overlay);
  await settle();
  await tester.tap(find.byTooltip('Section view'));
  await settle();
  expect(
    controller.scene.clippingPlanes,
    hasLength(1),
    reason:
        'Status: ${controller.status.value}; text: ${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).join(" | ")}',
  );
  await tester.tap(find.byKey(const ValueKey('section-axis')));
  await settle();
  await tester.tap(find.text('Cut X').last);
  await settle();
  if (controller.scene.clippingPlanes.single.normal.x < 0) {
    await tester.tap(find.byTooltip('Flip section'));
    await settle();
  }
  expect(controller.scene.clippingPlanes.single.normal, const Vec3(1, 0, 0));
  final slider = find.byKey(const ValueKey('section-offset'));
  final rect = tester.getRect(slider);
  await tester.tapAt(rect.center);
  await settle();
  expect(capsInScene(), isNotEmpty);
  await tester.tap(caps);
  await settle();
  expect(capsInScene(), isEmpty);
  await tester.tap(caps);
  await settle();
  expect(capsInScene(), isNotEmpty);

  await tester.tapAt(Offset(rect.left + rect.width * .75, rect.center.dy));
  await settle();
  final offset = controller.scene.clippingPlanes.single.offset;
  expect(offset, greaterThan(0));
  await tester.tap(find.byKey(const ValueKey('section-axis')));
  await settle();
  await tester.tap(find.text('Cut Z').last);
  await settle();
  expect(controller.scene.clippingPlanes.single.normal, const Vec3(0, 0, 1));
  await tester.tap(find.byTooltip('Flip section'));
  await settle();
  expect(controller.scene.clippingPlanes.single.normal, const Vec3(0, 0, -1));
  expect(controller.scene.clippingPlanes.single.offset, -offset);
  final helper = controller.scene.children.single.children.firstWhere(
    (node) => node.name == 'Transform gizmo',
  );
  expect(helper.clippingEnabled, isFalse);
  expect(helper.visible, isTrue);
  expect(tester.takeException(), isNull);
  await tester.tap(find.byTooltip('Clear section'));
  await settle();
  expect(controller.scene.clippingPlanes, isEmpty);
  expect(find.byKey(const ValueKey('section-offset')), findsNothing);
}
