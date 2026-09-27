import 'dart:io';
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
        fail('Native workbench did not reach the expected state.');
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
      await tester.tap(find.byTooltip('Move +X'));
      await until(() => housing.position != original);
      expect(housing.position, original + const Vec3(.25, 0, 0));
      await tester.tap(find.byTooltip('Undo'));
      await until(() => housing.position == original);
      await tester.tap(find.byKey(const ValueKey('part-Cover')));
      final cover = controller.scene.children.single.children.last as Mesh;
      await until(() => cover.material.color == Color3.hex(0xf2bd65));
      tester.widget<Slider>(find.byKey(const ValueKey('timeline'))).onChanged!(
        1,
      );
      await until(() => cover.position.x == 2.4);
      await tester.tap(find.byTooltip('Play'));
      await until(() => cover.position.x > .95 && cover.position.x < 2.4);
      await tester.tap(find.byTooltip('Pause'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(frames.map((frame) => frame.readbackBytes), everyElement(0));
      expect(frames.last.drawCalls, 3);
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
