import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren/src/presentation/native_metal_presenter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:integration_test/integration_test.dart';
import 'package:model_viewer/main.dart';
import '../test/support/controls.dart';
import '../../../packages/zyren_native/test/support/gltf_deformation_checks.dart';
import '../../../packages/zyren_native/test/support/morph_tangent_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'imported skin and morph animation presents natively and settles on pause',
    (tester) async {
      final backend = Platform.isAndroid
          ? await NativeBackend.create()
          : await NativeMetalBackend.create();
      try {
        await verifyGltfDeformation(backend);
        await verifyMorphTangents(backend);
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
      final sub = controller.frameStats.listen(frames.add);
      Future<void> ready(String name, int draws) async {
        for (var i = 0; i < 250; i++) {
          await tester.pump(const Duration(milliseconds: 40));
          if (controller.status.value case SceneFailed(:final issue)) {
            fail(issue.message);
          }
          if (controller.scene.children.isNotEmpty &&
              controller.scene.children.single.name == name &&
              frames.isNotEmpty &&
              frames.last.drawCalls == draws &&
              find.text('Cancel').evaluate().isEmpty) {
            return;
          }
        }
        fail('No native frame for $name');
      }

      Future<void> advance() async {
        for (var i = 0; i < 16; i++) {
          await tester.pump(const Duration(milliseconds: 30));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      try {
        await ready('Assembly', 3);
        for (final normalMapped in [false, true]) {
          frames.clear();
          await chooseExample(
            tester,
            normalMapped ? 'Skin + normal map' : 'Skin + morph',
          );
          await ready(
            normalMapped ? 'Normal-mapped ribbons' : 'Skinned ribbons',
            2,
          );
          final instance = controller.scene.children.single as ModelInstance;
          final mesh = instance.nodes[3]!.children
              .whereType<SkinnedMesh>()
              .single;
          final other = instance.nodes[6]!.children
              .whereType<SkinnedMesh>()
              .single;
          expect(mesh.geometry, same(other.geometry));
          final independent = other.captureDeformation();
          tester
              .widget<Slider>(find.byKey(const ValueKey('Animation playhead')))
              .onChanged!(1);
          await advance();
          expect(mesh.morphWeights, [1, if (normalMapped) 1]);
          if (normalMapped) {
            expect(
              mesh.geometry.morphTargets.every((t) => t.tangents != null),
              isTrue,
            );
          }
          expect(other.captureDeformation(), same(independent));
          expect(frames.any((f) => f.uploadedBytes == 400), isTrue);
          expect(frames.every((f) => f.readbackBytes == 0), isTrue);
          await tester.tap(find.byKey(const ValueKey('Animation playback')));
          await advance();
          expect(mesh.morphWeights, isNot([1, if (normalMapped) 1]));
          await tester.tap(find.byKey(const ValueKey('Animation playback')));
          await advance();
          final settled = frames.length;
          await advance();
          expect(frames.length, settled);
          expect(tester.takeException(), isNull);
        }
      } finally {
        await sub.cancel();
        await tester.pumpWidget(const SizedBox());
        await controller.whenDisposed;
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
