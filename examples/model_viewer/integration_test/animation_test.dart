import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_gpu3d/src/presentation/native_metal_presenter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:integration_test/integration_test.dart';
import 'package:model_viewer/main.dart';
import '../test/support/controls.dart';
import '../../../packages/gpu3d_native/test/support/gltf_animation_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'imported clips play through native presentation and release demand',
    (tester) async {
      final backend = Platform.isAndroid
          ? await NativeBackend.create()
          : await NativeMetalBackend.create();
      try {
        await verifyGltfAnimation(backend);
      } finally {
        await backend.close();
      }
      await tester.pumpWidget(
        ModelViewerApp(
          runtime: Platform.isAndroid
              ? const SceneRuntime.nativeAndroid()
              : const SceneRuntime.nativeMetal(),
          autoplayAnimations: false,
        ),
      );
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      final frames = <FrameStats>[];
      final subscription = controller.frameStats.listen(frames.add);
      Future<void> ready(String name) async {
        for (var i = 0; i < 250; i++) {
          await tester.pump(const Duration(milliseconds: 40));
          if (controller.status.value case SceneFailed(:final issue)) {
            fail(issue.message);
          }
          if (controller.scene.children.isNotEmpty &&
              controller.scene.children.single.name == name &&
              frames.isNotEmpty &&
              frames.last.drawCalls == 3 &&
              find.text('Cancel').evaluate().isEmpty) {
            return;
          }
        }
        fail('No native frame for $name: ${controller.status.value}');
      }

      Future<void> advance() async {
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      try {
        await ready('Assembly');
        frames.clear();
        await chooseExample(tester, 'Animation');
        await ready('Animated assembly');
        final instance = controller.scene.children.single as ModelInstance;
        final start = instance.nodes[2]!.position;
        expect(instance.mixer.isAdvancing, isFalse);
        await tester.tap(find.byKey(const ValueKey('Animation playback')));
        await advance();
        expect(instance.nodes[2]!.position, isNot(start));
        await tester.tap(find.byKey(const ValueKey('Animation playback')));
        await advance();
        final settled = frames.length;
        await advance();
        expect(frames.length, settled);
        final paused = instance.nodes[2]!.position;
        await tester.drag(
          find.byKey(const ValueKey('Animation playhead')),
          const Offset(30, 0),
        );
        await advance();
        expect(instance.nodes[2]!.position, isNot(paused));
        expect(frames.last.uploadedBytes, 0);
        expect(frames.every((f) => f.readbackBytes == 0), isTrue);
        await tester.tap(find.byKey(const ValueKey('Animation playback')));
        await advance();
        await chooseExample(tester, 'GLB');
        await ready('Assembly');
        expect(instance.mixer.actions, isEmpty);
        await advance();
        final replaced = frames.length;
        await advance();
        expect(frames.length, replaced);
        expect(tester.takeException(), isNull);
      } finally {
        await subscription.cancel();
        await tester.pumpWidget(const SizedBox());
        await controller.whenDisposed;
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
