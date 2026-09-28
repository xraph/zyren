import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:model_viewer/deformation.dart';
import '../../../packages/flutter_gpu3d/test/support/backend_fake.dart';
import '../../../packages/flutter_gpu3d/test/support/fakes.dart';

class DeformationBackend extends FakeBackend {
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'deformation-test',
    features: RenderFeature.values.toSet(),
    limits: DeviceLimits(
      maxTextureDimension2D: 4096,
      maxGeometryBytes: 64 * 1024 * 1024,
      maxJoints: 256,
      maxMorphTargets: 64,
      maxPunctualLights: 16,
      maxHemisphereLights: 4,
    ),
  );
}

void main() {
  for (final size in [const Size(1000, 700), const Size(320, 640)]) {
    testWidgets(
      'deformation controls fit $size and leave the second pose alone',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final backend = DeformationBackend();
        await tester.pumpWidget(
          DeformationApp(
            runtime: SceneRuntime(
              backendFactory: () async => backend,
              presenterFactory: () =>
                  TestPresenter('native frame', backend.events),
            ),
          ),
        );
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        final controller = tester
            .widget<SceneView>(find.byType(SceneView))
            .controller!;
        final meshes = [
          for (final group in controller.scene.children.whereType<Group>())
            ...group.children.whereType<SkinnedMesh>(),
        ];
        expect(meshes, hasLength(2));
        final independent = meshes[1].captureDeformation();
        await tester.tap(find.byKey(const ValueKey('Deformation playback')));
        await tester.pump();
        tester
            .widget<Slider>(find.byKey(const ValueKey('Deformation morph')))
            .onChanged!(1.2);
        tester
            .widget<Slider>(find.byKey(const ValueKey('Deformation playhead')))
            .onChanged!(1);
        await tester.pump();
        expect(meshes[0].morphWeights, [1.2]);
        expect(meshes[1].captureDeformation(), same(independent));
        expect(
          tester.getSize(find.byType(SceneView)).height,
          greaterThan(size.height * .55),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => controller.whenDisposed);
      },
    );
  }
}
