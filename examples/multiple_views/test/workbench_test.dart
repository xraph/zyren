import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_tools/zyren_tools.dart';
import 'package:multiple_views/scene_workbench.dart';
import '../../../packages/flutter_zyren/test/support/backend_fake.dart';
import '../../../packages/flutter_zyren/test/support/fakes.dart';

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  testWidgets(
    'workbench edits, undoes and scrubs at desktop and narrow widths',
    (tester) async {
      final backend = FakeBackend();
      await tester.binding.setSurfaceSize(const Size(1100, 760));
      await tester.pumpWidget(
        SceneWorkbenchApp(
          runtime: SceneRuntime(
            backendFactory: () async => backend,
            presenterFactory: () => TestPresenter('frame', backend.events),
          ),
          presentation: PresentationPolicy.readbackOnly,
        ),
      );
      await frames(tester);
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      final housing = controller.scene.children.single.children.first;
      final start = housing.position;
      Offset project(Vec3 point) {
        final view = find.byType(SceneView);
        final size = tester.getSize(view);
        final p = controller.camera.projectPoint(point, size.aspectRatio);
        return tester.getTopLeft(view) +
            Offset((p.x + 1) * size.width / 2, (1 - p.y) * size.height / 2);
      }

      final cameraPosition = controller.camera.position;
      final gesture = await tester.startGesture(project(const Vec3(0, 2, 0)));
      await frames(tester);
      await gesture.moveTo(project(const Vec3(0, 2.5, 0)));
      await frames(tester);
      await gesture.up();
      await frames(tester);
      expect(housing.position.y, closeTo(.5, 1e-6));
      expect(controller.camera.position, cameraPosition);
      await tester.tap(find.byTooltip('Undo'));
      await frames(tester);
      expect(housing.position, start);
      expect(find.text('3 parts'), findsOneWidget);
      housing.quaternion = Quat.axisAngle(const Vec3(1, 0, 0), .35);
      await tester.tap(find.byKey(const ValueKey('gizmo-space')));
      await frames(tester);
      await tester.tap(find.text('World').last);
      await frames(tester);
      final plane = await tester.startGesture(project(const Vec3(1.3, 1.3, 0)));
      await frames(tester);
      expect(find.text('Drag XY · Esc cancels'), findsOneWidget);
      await plane.moveTo(project(const Vec3(1.8, 1.55, 0)));
      await frames(tester);
      await plane.up();
      await frames(tester);
      expect(
        housing.position.distanceTo(const Vec3(.5, .25, 0)),
        lessThan(1e-6),
      );
      expect(controller.camera.position, cameraPosition);
      await tester.tap(find.byTooltip('Undo'));
      await frames(tester);
      expect(housing.position, start);
      housing.quaternion = Quat.identity;
      final mode = tester.widget<DropdownButton<GizmoMode>>(
        find.byKey(const ValueKey('gizmo-mode')),
      );
      housing.parent!.scale = const Vec3(2, 1, 1);
      mode.onChanged!(GizmoMode.rotate);
      await frames(tester);
      expect(
        find.text(
          'World rotation requires uniform parent scale. Choose Local.',
        ),
        findsOneWidget,
      );
      housing.parent!.scale = Vec3.one;
      mode.onChanged!(GizmoMode.scale);
      await frames(tester);
      final scaleSpace = tester.widget<DropdownButton<GizmoSpace>>(
        find.byKey(const ValueKey('gizmo-space')),
      );
      expect(scaleSpace.value, GizmoSpace.local);
      expect(scaleSpace.onChanged, isNull);
      final scaleGesture = await tester.startGesture(
        project(const Vec3(0, 2, 0)),
      );
      await frames(tester);
      await scaleGesture.moveTo(project(const Vec3(0, 3, 0)));
      await frames(tester);
      await scaleGesture.up();
      await frames(tester);
      expect(housing.scale.y, closeTo(1.5, 1e-6));
      await tester.tap(find.byTooltip('Undo'));
      await frames(tester);
      mode.onChanged!(GizmoMode.translate);
      await frames(tester);
      expect(
        tester
            .widget<DropdownButton<GizmoSpace>>(
              find.byKey(const ValueKey('gizmo-space')),
            )
            .value,
        GizmoSpace.world,
      );
      await tester.tap(find.byTooltip('Move +X'));
      await frames(tester);
      expect(housing.position, start + const Vec3(.25, 0, 0));
      await tester.tap(find.byTooltip('Undo'));
      await frames(tester);
      expect(housing.position, start);
      await tester.tap(find.byTooltip('Redo'));
      await frames(tester);
      expect(housing.position, start + const Vec3(.25, 0, 0));
      await tester.tap(find.byKey(const ValueKey('part-Cover')));
      await frames(tester);
      final cover =
          controller.scene.children.single.children.firstWhere(
                (object) => object.name == 'Cover',
              )
              as Mesh;
      expect(cover.material.color, Color3.hex(0xf2bd65));
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('timeline')),
      );
      slider.onChanged!(1);
      await frames(tester);
      expect(cover.position.x, 2.4);
      await tester.binding.setSurfaceSize(const Size(390, 700));
      await frames(tester);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(250));
      await tester.tap(find.byTooltip('Play'));
      await frames(tester);
      expect(find.byTooltip('Pause'), findsOneWidget);
      await tester.tap(find.byTooltip('Pause'));
      await frames(tester);
      final helper = controller.scene.children.single.children.firstWhere(
        (object) => object.name == 'Transform gizmo',
      );
      expect(helper.visible, isTrue);
      await tester.binding.setSurfaceSize(const Size(320, 640));
      await frames(tester);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(200));
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(controller.isDisposed, isTrue);
      var disposed = false;
      controller.whenDisposed.then((_) => disposed = true);
      for (var i = 0; i < 20 && !disposed; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      expect(disposed, isTrue);
      await tester.binding.setSurfaceSize(null);
    },
  );
}
