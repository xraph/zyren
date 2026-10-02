import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multiple_views/declarative_demo.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'declarative scene presents natively and retains objects on edits',
    (tester) async {
      late SceneController controller;
      await tester.pumpWidget(
        DeclarativeDemo(onCreated: (value) => controller = value),
      );
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          if (ready()) return;
        }
        fail(
          'Timed out waiting for the declarative scene: ${controller.status.value}',
        );
      }

      await until(
        () =>
            controller.latestFrameStats != null ||
            controller.status.value is SceneFailed,
      );
      expect(controller.status.value, isA<SceneReady>());
      final first = controller.latestFrameStats!;
      expect(
        first.presentationPath,
        Platform.isAndroid
            ? PresentationPath.sharedTexture
            : PresentationPath.nativeView,
      );
      expect(first.readbackBytes, 0);
      expect(first.drawCalls, 2);
      final group = controller.scene.children.single;
      final cube = group.children.first as Mesh;
      final sphere = group.children.last;
      await tester.tap(find.text('Pause'));
      await tester.pump();
      final orientation = cube.quaternion;
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(cube.quaternion, orientation);
      final view = tester.getRect(find.byType(SceneView));
      final ndc = controller.camera.projectPoint(
        cube.position,
        view.width / view.height,
      );
      await tester.tapAt(
        Offset(
          view.left + (ndc.x + 1) * view.width / 2,
          view.top + (1 - ndc.y) * view.height / 2,
        ),
      );
      await until(() => find.text('Cube selected').evaluate().isNotEmpty);
      expect(group.children.first, same(cube));
      expect(cube.material.color, const Color3(.3, .85, .65));
      await tester.tap(find.text('Remove cube'));
      await until(() => controller.latestFrameStats?.drawCalls == 1);
      expect(group.children, [sphere]);
      await tester.tap(find.text('Add cube'));
      await until(() => controller.latestFrameStats?.drawCalls == 2);
      expect(group.children, contains(sphere));
      expect(controller.latestFrameStats!.readbackBytes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => controller.whenDisposed.timeout(const Duration(seconds: 15)),
      );
      expect(controller.isDisposed, isTrue);
    },
  );
}
