import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/picking_lab.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native selection, projection changes, misses and narrow layout',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 760));
      await tester.pumpWidget(const PickingLabApp());
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      var frames = 0;
      final android = defaultTargetPlatform == TargetPlatform.android;
      final stats = controller.frameStats.listen((value) {
        expectSync(
          value.presentationPath,
          android
              ? PresentationPath.sharedTexture
              : PresentationPath.nativeView,
        );
        expectSync(value.readbackBytes, 0);
        frames++;
      });
      Future<void> waitFrame(int previous) async {
        for (var i = 0; i < 240; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          if (controller.status.value case SceneFailed(:final issue)) {
            fail('$issue');
          }
          if (frames > previous) return;
          if (i % 10 == 0) controller.invalidate();
        }
        fail('Native picking frame did not arrive');
      }

      final meshes = controller.scene.children.cast<Mesh>().toList();
      final originalMaterials = [for (final mesh in meshes) mesh.material];
      Future<void> select(int index, String name) async {
        final viewport = tester.getRect(find.byType(SceneView));
        final ndc = controller.camera.projectPoint(
          meshes[index].position,
          viewport.width / viewport.height,
        );
        final logical = ViewportPoint(
          (ndc.x + 1) * viewport.width / 2,
          (1 - ndc.y) * viewport.height / 2,
        );
        final hit = (await controller.pick(logical))!;
        expect(hit.object, same(meshes[index]));
        expect(hit.normal.length, closeTo(1, 1e-10));
        expect(hit.distance, greaterThan(0));
        if (index == 2) {
          expect(hit.point.distanceTo(meshes[index].position), lessThan(1e-9));
          expect(hit.uv!.u, closeTo(.5, 1e-9));
          expect(hit.uv!.v, closeTo(.5, 1e-9));
        }
        final before = frames;
        await tester.tapAt(viewport.topLeft + Offset(logical.x, logical.y));
        await waitFrame(before);
        expect(find.textContaining('$name ·'), findsOneWidget);
        expect(meshes[index].material, isNot(same(originalMaterials[index])));
        for (var i = 0; i < meshes.length; i++) {
          if (i != index) {
            expect(meshes[i].material, same(originalMaterials[i]));
          }
        }
        expect(tester.takeException(), isNull);
      }

      await waitFrame(0);
      for (final orthographic in [false, true]) {
        if (orthographic) {
          final before = frames;
          await tester.tap(find.text('Orthographic'));
          await waitFrame(before);
        }
        await select(0, 'Box');
        await select(1, 'Sphere');
        await select(2, 'Panel');
        final rect = tester.getRect(find.byType(SceneView));
        await tester.tapAt(rect.topLeft + const Offset(10, 10));
        await tester.pump();
        expect(
          find.text('Tap a surface to select it. Drag to orbit.'),
          findsOneWidget,
        );
        for (var i = 0; i < meshes.length; i++) {
          expect(meshes[i].material, same(originalMaterials[i]));
        }
      }
      await tester.binding.setSurfaceSize(const Size(390, 700));
      await tester.pump(const Duration(milliseconds: 300));
      await select(2, 'Panel');
      final rect = tester.getRect(find.byType(SceneView));
      final beforeDrag = controller.camera.position;
      await tester.dragFrom(rect.center, const Offset(30, 15));
      await tester.pump();
      expect(
        controller.camera.position.distanceTo(beforeDrag),
        greaterThan(.01),
      );
      expect(find.textContaining('Panel ·'), findsOneWidget);
      await tester.tap(find.text('Clear selection'));
      await tester.pump();
      expect(meshes[2].material, same(originalMaterials[2]));
      expect(tester.takeException(), isNull);
      // Suspending a held pointer delivers a synthetic cancel through input.
      // No physical up event arrives before the next independent click.
      final interrupted = await tester.startGesture(rect.center, pointer: 42);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final beforeResume = frames;
      await waitFrame(beforeResume);
      await select(0, 'Box');
      await interrupted.cancel();
      await tester.pumpWidget(const SizedBox());
      await controller.whenDisposed;
      await stats.cancel();
      final diagnostics = await MethodChannel(
        android ? 'gpu3d/android-surfaces' : 'gpu3d/scene-views',
      ).invokeMapMethod<Object?, Object?>('diagnostics');
      expect(diagnostics!['sessions'], 0);
      expect(diagnostics['renderers'], 0);
      expect(diagnostics[android ? 'surfaces' : 'heldDrawables'], 0);
      expect(diagnostics['retiring'], 0);
      expect(diagnostics['readbackBytes'], 0);
      debugPrint('Picking native cleanup: $diagnostics; samples=$frames');
      await tester.binding.setSurfaceSize(null);
    },
  );
}
