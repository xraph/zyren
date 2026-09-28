import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_gpu3d/src/presentation/native_metal_presenter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:model_viewer/deformation.dart';
import '../../../packages/gpu3d_native/test/support/deformation_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native deformation retains poses and releases frame demand when paused',
    (tester) async {
      final backend = Platform.isAndroid
          ? await NativeBackend.create()
          : await NativeMetalBackend.create();
      try {
        await verifyDeformationMaterials(backend);
        await verifyDeformationShadows(backend);
        await verifyDeformationBlendOrder(backend);
      } finally {
        await backend.close();
      }
      await tester.pumpWidget(
        DeformationApp(
          runtime: Platform.isAndroid
              ? const SceneRuntime.nativeAndroid()
              : const SceneRuntime.nativeMetal(),
        ),
      );
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      final frames = <FrameStats>[];
      final sub = controller.frameStats.listen(frames.add);
      Future<void> waitFrames(int start) async {
        for (var i = 0; i < 250; i++) {
          await tester.pump(const Duration(milliseconds: 40));
          if (controller.status.value case SceneFailed(:final issue)) {
            fail(issue.message);
          }
          if (frames.length > start) return;
        }
        fail('Deformation frame was not presented.');
      }

      try {
        await waitFrames(1);
        final meshes = <SkinnedMesh>[
          for (final group in controller.scene.children.whereType<Group>())
            ...group.children.whereType<SkinnedMesh>(),
        ];
        expect(meshes, hasLength(2));
        expect(meshes[0].geometry, same(meshes[1].geometry));
        final independent = meshes[1].captureDeformation();
        await tester.tap(find.byKey(const ValueKey('Deformation playback')));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final settled = frames.length;
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(frames.length, settled);
        final slider = tester.widget<Slider>(
          find.byKey(const ValueKey('Deformation morph')),
        );
        slider.onChanged!(1);
        await waitFrames(settled);
        expect(frames.last.uploadedBytes, 400);
        expect(meshes[1].captureDeformation(), same(independent));
        final before = frames.length;
        tester
            .widget<Slider>(find.byKey(const ValueKey('Deformation playhead')))
            .onChanged!(1);
        await waitFrames(before);
        expect(frames.last.uploadedBytes, 400);
        expect(frames.every((f) => f.readbackBytes == 0), isTrue);
        await tester.tap(find.byKey(const ValueKey('Deformation playback')));
        await waitFrames(frames.length);
        expect(tester.takeException(), isNull);
      } finally {
        await sub.cancel();
        await tester.pumpWidget(const SizedBox());
        await controller.whenDisposed;
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
