import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multiple_views/declarative_demo.dart';

class RetryBundleResolver implements ByteSourceResolver {
  int textureReads = 0;
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    if (uri.path.endsWith('corners.png') && ++textureReads == 1) {
      throw StateError('Injected first texture read failure');
    }
    return const FlutterSourceResolver().read(uri, context);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'declarative scene presents natively and retains objects on edits',
    (tester) async {
      late SceneController controller;
      final presented = <FrameStats>[];
      final resolver = RetryBundleResolver();
      const defaults = SceneRuntime.defaultAssetServices;
      final services = AssetServices(
        resolver: resolver,
        imageDecoder: defaults.imageDecoder,
        textureDecoder: defaults.textureDecoder,
        bufferDecoder: defaults.bufferDecoder,
        meshDecoder: defaults.meshDecoder,
        hdrImageDecoder: defaults.hdrImageDecoder,
        tangentGenerator: defaults.tangentGenerator,
      );
      await tester.pumpWidget(
        DeclarativeDemo(
          runtime: Platform.isAndroid
              ? SceneRuntime.nativeAndroid(assetServices: services)
              : SceneRuntime.nativeMetal(assetServices: services),
          onCreated: (value) {
            controller = value;
            final subscription = value.presentations.listen(
              (sample) => presented.add(sample.frame),
            );
            addTearDown(subscription.cancel);
          },
        ),
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

      await until(() => find.text('Retry asset').evaluate().isNotEmpty);
      expect(find.text('Asset could not load'), findsOneWidget);
      await tester.tap(find.text('Retry asset'));
      await until(
        () =>
            ((controller.latestFrameStats?.drawCalls ?? 0) >= 4 &&
                controller.scene.children.any(
                  (node) => node.name == 'bundled-model',
                ) &&
                controller.scene.children.any(
                  (node) => node.name == 'textured-sphere',
                )) ||
            controller.status.value is SceneFailed,
      );
      expect(controller.status.value, isA<SceneReady>());
      expect(resolver.textureReads, 2);
      expect(find.text('Asset could not load'), findsNothing);
      final model =
          controller.scene.children.singleWhere(
                (node) => node.name == 'bundled-model',
              )
              as ModelInstance;
      final initialPose = model.nodes[0]!.position;
      await until(() => model.nodes[0]!.position != initialPose);
      final first = controller.latestFrameStats!;
      expect(
        first.presentationPath,
        Platform.isAndroid
            ? PresentationPath.sharedTexture
            : PresentationPath.nativeView,
      );
      expect(first.readbackBytes, 0);
      expect(first.drawCalls, greaterThanOrEqualTo(4));
      final renderer = controller.state.value.renderer;
      final camera = controller.camera;
      final group = controller.scene.children.singleWhere(
        (node) => node.name == 'primitives',
      );
      final cube =
          group.children.singleWhere((node) => node.name == 'cube') as Mesh;
      final sphere = group.children.singleWhere(
        (node) => node.name == 'instances',
      );
      await tester.tap(find.text('Pause'));
      await tester.pump();
      final orientation = cube.quaternion;
      final pausedPose = model.nodes[0]!.position;
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(cube.quaternion, orientation);
      expect(model.nodes[0]!.position, pausedPose);
      final view = tester.getRect(find.byType(SceneView));
      final ndc = controller.camera.projectPoint(
        cube.position,
        view.width / view.height,
      );
      final cubePoint = Offset(
        view.left + (ndc.x + 1) * view.width / 2,
        view.top + (1 - ndc.y) * view.height / 2,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: view.bottomRight - const Offset(10, 10));
      await mouse.moveTo(cubePoint);
      await tester.pump();
      expect(find.text('Cube hovered'), findsOneWidget);
      await mouse.down(cubePoint);
      await mouse.moveTo(view.bottomLeft + const Offset(15, -15));
      await tester.pump();
      expect(find.text('Dragging captured cube'), findsOneWidget);
      await mouse.up();
      await mouse.removePointer();
      await tester.tapAt(cubePoint);
      await until(() => find.text('Cube selected').evaluate().isNotEmpty);
      expect(group.children.first, same(cube));
      expect(cube.material.color, const Color3(.3, .85, .65));
      await tester.tap(find.text('Remove cube'));
      await until(
        () => controller.latestFrameStats?.drawCalls == first.drawCalls - 1,
      );
      expect(group.children, [sphere]);
      await tester.tap(find.text('Add cube'));
      await until(
        () => controller.latestFrameStats?.drawCalls == first.drawCalls,
      );
      expect(group.children, contains(sphere));
      await tester.tap(find.widgetWithText(FilterChip, 'Orbit'));
      await until(() => !controller.pluginIds.contains('zyren.orbit-controls'));
      await tester.tap(find.widgetWithText(FilterChip, 'Orbit'));
      await until(() => controller.pluginIds.contains('zyren.orbit-controls'));
      final beforeEffects = controller.latestFrameStats!.frameId;
      await tester.tap(find.widgetWithText(FilterChip, 'FXAA'));
      await until(
        () =>
            controller.pluginIds.contains('zyren.post-processing') &&
            controller.latestFrameStats!.frameId > beforeEffects,
      );
      expect(controller.pluginIssue, isNull);
      expect(controller.latestFrameStats!.readbackBytes, 0);
      final withEffects = controller.latestFrameStats!.frameId;
      await tester.tap(find.widgetWithText(FilterChip, 'FXAA'));
      await until(
        () =>
            !controller.pluginIds.contains('zyren.post-processing') &&
            controller.latestFrameStats!.frameId > withEffects,
      );
      await tester.tapAt(view.bottomRight - const Offset(12, 12));
      await until(() => find.text('Background clicked').evaluate().isNotEmpty);
      expect(controller.selection, isNull);
      expect(controller.camera, same(camera));
      expect(controller.state.value.renderer, same(renderer));
      expect(controller.latestFrameStats!.readbackBytes, 0);
      expect(presented, isNotEmpty);
      for (final frame in presented) {
        expect(frame.readbackBytes, 0);
        expect(frame.presentationPath, first.presentationPath);
      }
      expect(controller.pluginIssue, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => controller.whenDisposed.timeout(const Duration(seconds: 15)),
      );
      expect(controller.isDisposed, isTrue);
    },
  );
}
