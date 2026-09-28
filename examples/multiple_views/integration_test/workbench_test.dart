import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multiple_views/scene_workbench.dart';
import '../test/support/workbench_gizmo.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native workbench selects edits undoes scrubs and releases its view',
    (tester) async {
      await tester.pumpWidget(
        SceneWorkbenchApp(
          runtime: Platform.isAndroid
              ? const SceneRuntime.nativeAndroid()
              : const SceneRuntime.nativeMetal(),
        ),
      );
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      final frames = <FrameStats>[];
      final subscription = controller.frameStats.listen(frames.add);
      Future<void> until(bool Function() condition) async {
        for (var i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          if (condition()) return;
          if (controller.status.value is SceneFailed) {
            fail('${controller.status.value}');
          }
        }
        fail(
          'Native workbench did not reach the expected state. '
          'Last draws: ${frames.lastOrNull?.drawCalls}; '
          'current draws: ${FrameSubmission.capture(scene: controller.scene, camera: controller.camera, size: PhysicalSize(100, 100)).scene.drawCalls}; '
          'play button: ${find.byTooltip('Play').evaluate().length}; '
          'pause button: ${find.byTooltip('Pause').evaluate().length}.',
        );
      }

      await until(() => frames.isNotEmpty);
      expect(
        (await controller.ready).presentationPath,
        Platform.isAndroid
            ? PresentationPath.sharedTexture
            : PresentationPath.nativeView,
      );
      final housing = controller.scene.children.single.children.first;
      final original = housing.position;
      Offset project(Vec3 point) {
        final view = find.byType(SceneView);
        final size = tester.getSize(view);
        final p = controller.camera.projectPoint(point, size.aspectRatio);
        return tester.getTopLeft(view) +
            Offset((p.x + 1) * size.width / 2, (1 - p.y) * size.height / 2);
      }

      final cameraPosition = controller.camera.position;
      double radius() => workbenchGizmoRadius(controller);
      // Keep depth-tested rings outside the part even in a large native window.
      if (radius() < 2) {
        controller.camera.position = cameraPosition * (2 / radius());
        await until(() => radius() >= 2 - 1e-6);
      }
      final editingCameraPosition = controller.camera.position;
      double r = radius();
      final gesture = await tester.startGesture(project(Vec3(0, r, 0)));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveTo(project(Vec3(0, r + .5, 0)));
      await until(() => housing.position.y > .4);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(housing.position.y, closeTo(.5, 1e-5));
      expect(controller.camera.position, editingCameraPosition);
      await tester.tap(find.byTooltip('Undo'));
      await until(() => housing.position == original);
      Future<void> mode(String label) async {
        await tester.tap(find.byKey(const ValueKey('gizmo-mode')));
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text(label).last);
        await tester.pump(const Duration(milliseconds: 250));
      }

      await mode('Rotate');
      Vec3 ringPoint(double angle) =>
          Vec3(r * .85 * math.cos(angle), r * .85 * math.sin(angle), 0);
      final rotation = await tester.startGesture(
        project(ringPoint(math.pi / 4)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await rotation.moveTo(project(ringPoint(math.pi / 4 + math.pi / 6)));
      await until(() => housing.quaternion.z.abs() > .2);
      await rotation.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(housing.quaternion.z, closeTo(math.sin(math.pi / 12), 1e-5));
      await tester.tap(find.byTooltip('Undo'));
      await until(() => housing.quaternion == Quat.identity);
      await mode('Scale');
      r = radius();
      final scale = await tester.startGesture(project(Vec3(0, r, 0)));
      await tester.pump(const Duration(milliseconds: 100));
      await scale.moveTo(project(Vec3(0, r * 1.5, 0)));
      await until(() => housing.scale.y > 1.4);
      await scale.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(housing.scale.y, closeTo(1.5, 1e-5));
      await tester.tap(find.byTooltip('Undo'));
      await until(() => housing.scale == Vec3.one);
      await mode('Move');
      r = radius();
      final cancelled = await tester.startGesture(project(Vec3(0, r, 0)));
      await tester.pump(const Duration(milliseconds: 100));
      await cancelled.moveTo(project(Vec3(0, r + .5, 0)));
      await until(() => housing.position.y > .4);
      await cancelled.cancel();
      await until(() => housing.position == original);
      expect(controller.camera.position, editingCameraPosition);
      // A rotated part distinguishes world coordinates from its local frame.
      final tilted = Quat.axisAngle(const Vec3(1, 0, 0), .35);
      housing.quaternion = tilted;
      await tester.tap(find.byKey(const ValueKey('gizmo-space')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('World').last);
      await tester.pump(const Duration(milliseconds: 250));
      r = radius();
      final worldAxis = await tester.startGesture(project(Vec3(0, r, 0)));
      await tester.pump(const Duration(milliseconds: 100));
      await worldAxis.moveTo(project(Vec3(0, r + .5, 0)));
      await until(() => housing.position.y > .4);
      await worldAxis.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(housing.position.distanceTo(const Vec3(0, .5, 0)), lessThan(1e-5));
      await tester.tap(find.byTooltip('Undo'));
      await until(() => housing.position == original);
      await tester.tap(find.byTooltip('Snap: 0.25 units / 15° / 10%'));
      await tester.pump(const Duration(milliseconds: 100));
      r = radius();
      final plane = await tester.startGesture(
        project(Vec3(r * .65, r * .65, 0)),
      );
      await until(
        () => find.text('Drag XY · Esc cancels').evaluate().isNotEmpty,
      );
      await plane.moveTo(project(Vec3(r * .65 + .31, r * .65 + .56, 0)));
      await until(() => housing.position.x > .2);
      await plane.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        housing.position.distanceTo(const Vec3(.25, .5, 0)),
        lessThan(1e-5),
      );
      expect(controller.camera.position, editingCameraPosition);
      await tester.tap(find.byTooltip('Undo'));
      await until(() => housing.position == original);
      await tester.tap(find.byTooltip('Snap: 0.25 units / 15° / 10%'));
      await mode('Rotate');
      r = radius();
      final worldRing = await tester.startGesture(
        project(ringPoint(math.pi / 4)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await worldRing.moveTo(project(ringPoint(math.pi / 4 + .3)));
      await until(() => housing.quaternion.z.abs() > .1);
      await worldRing.up();
      await tester.pump(const Duration(milliseconds: 100));
      final expectedRotation = Quat.axisAngle(const Vec3(0, 0, 1), .3) * tilted;
      expect(
        housing.quaternion
            .rotate(Vec3.one)
            .distanceTo(expectedRotation.rotate(Vec3.one)),
        lessThan(1e-5),
      );
      await tester.tap(find.byTooltip('Undo'));
      await until(
        () =>
            housing.quaternion
                .rotate(Vec3.one)
                .distanceTo(tilted.rotate(Vec3.one)) <
            1e-9,
      );
      housing.quaternion = Quat.identity;
      await mode('Move');
      final beforeZoom = radius();
      // The workbench's orbit behavior uses one zoom step per wheel event.
      for (var i = 0; i < 3; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(find.byType(SceneView)),
            scrollDelta: const Offset(0, 100),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await until(() => radius() > beforeZoom * 1.1);
      r = radius();
      expect(
        r / beforeZoom,
        closeTo(
          controller.camera.position.length / editingCameraPosition.length,
          1e-5,
        ),
      );
      final zoomedCamera = controller.camera.position;
      final zoomed = await tester.startGesture(project(Vec3(0, r, 0)));
      await tester.pump(const Duration(milliseconds: 100));
      await zoomed.moveTo(project(Vec3(0, r + .5, 0)));
      await until(() => housing.position.y > .4);
      await zoomed.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(housing.position.y, closeTo(.5, 1e-5));
      expect(controller.camera.position, zoomedCamera);
      await tester.tap(find.byTooltip('Undo'));
      await until(() => housing.position == original);
      await tester.tap(find.byTooltip('Move +X'));
      await until(() => housing.position != original);
      expect(housing.position, original + const Vec3(.25, 0, 0));
      await tester.tap(find.byTooltip('Undo'));
      await until(() => housing.position == original);
      await tester.ensureVisible(find.byKey(const ValueKey('part-Cover')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('part-Cover')));
      final cover =
          controller.scene.children.single.children.firstWhere(
                (object) => object.name == 'Cover',
              )
              as Mesh;
      await until(() => cover.material.color == Color3.hex(0xf2bd65));
      tester.widget<Slider>(find.byKey(const ValueKey('timeline'))).onChanged!(
        1,
      );
      await until(() => cover.position.x == 2.4);
      await tester.tap(find.byTooltip('Play'));
      await until(() => cover.position.x > .95 && cover.position.x < 2.4);
      await tester.tap(find.byTooltip('Pause'));
      // Controller diagnostics sample at 5 Hz. Request a fresh sample after
      // that interval; a paused scene otherwise has no reason to draw again.
      await tester.pump(const Duration(milliseconds: 250));
      controller.invalidate();
      await until(() => frames.last.drawCalls == 12);
      expect(frames.map((frame) => frame.readbackBytes), everyElement(0));
      expect(frames.last.drawCalls, 12);
      expect(find.byType(RawImage), findsNothing);
      debugPrint(
        'Workbench native evidence: ${frames.length} samples, ${frames.last.drawCalls} draws, zero readback bytes.',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 50));
      await controller.whenDisposed;
      await subscription.cancel();
      expect(controller.isDisposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
