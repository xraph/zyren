import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multiple_views/scene_workbench.dart';

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
      final gesture = await tester.startGesture(project(const Vec3(0, 2, 0)));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveTo(project(const Vec3(0, 2.5, 0)));
      await until(() => housing.position.y > .4);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(housing.position.y, closeTo(.5, 1e-5));
      expect(controller.camera.position, cameraPosition);
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
          Vec3(1.7 * math.cos(angle), 1.7 * math.sin(angle), 0);
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
      final scale = await tester.startGesture(project(const Vec3(0, 2, 0)));
      await tester.pump(const Duration(milliseconds: 100));
      await scale.moveTo(project(const Vec3(0, 3, 0)));
      await until(() => housing.scale.y > 1.4);
      await scale.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(housing.scale.y, closeTo(1.5, 1e-5));
      await tester.tap(find.byTooltip('Undo'));
      await until(() => housing.scale == Vec3.one);
      await mode('Move');
      final cancelled = await tester.startGesture(project(const Vec3(0, 2, 0)));
      await tester.pump(const Duration(milliseconds: 100));
      await cancelled.moveTo(project(const Vec3(0, 2.5, 0)));
      await until(() => housing.position.y > .4);
      await cancelled.cancel();
      await until(() => housing.position == original);
      expect(controller.camera.position, cameraPosition);
      await tester.tap(find.byTooltip('Move +X'));
      await until(() => housing.position != original);
      expect(housing.position, original + const Vec3(.25, 0, 0));
      await tester.tap(find.byTooltip('Undo'));
      await until(() => housing.position == original);
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
      await until(() => frames.last.drawCalls == 9);
      expect(frames.map((frame) => frame.readbackBytes), everyElement(0));
      expect(frames.last.drawCalls, 9);
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
