import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shader_lab/geometry.dart';
import 'package:shader_lab_effects/shader_lab_effects.dart';
import '../../../packages/flutter_gpu3d/test/support/backend_fake.dart';
import '../../../packages/flutter_gpu3d/test/support/fakes.dart';

class GeometryBackend extends FakeBackend {
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'geometry fixture',
    features: {
      RenderFeature.indexedMeshes,
      RenderFeature.rgbaReadback,
      RenderFeature.instancing,
      RenderFeature.skinning,
      RenderFeature.morphTargets,
    },
    limits: DeviceLimits(
      maxTextureDimension2D: 2048,
      maxGeometryBytes: 1000000,
      maxInstances: 100,
      maxJoints: 10,
      maxMorphTargets: 10,
      maxPunctualLights: 16,
    ),
  );
}

void main() {
  testWidgets('geometry controls keep a large canvas and update both poses', (
    tester,
  ) async {
    final backend = GeometryBackend();
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GeometryLabApp(
        autoplay: false,
        runtime: SceneRuntime(
          backendFactory: () async => backend,
          presenterFactory: () => TestPresenter('geometry', backend.events),
        ),
        presentation: PresentationPolicy.readbackOnly,
        unsupported: UnsupportedEffects.bypass,
      ),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    final instanced = controller.scene.children
        .whereType<InstancedMesh>()
        .single;
    final skin = controller.scene.children
        .whereType<Group>()
        .single
        .children
        .whereType<SkinnedMesh>()
        .single;
    tester
        .widget<Slider>(find.byKey(const ValueKey('Geometry Width')))
        .onChanged!(1);
    await tester.pumpAndSettle();
    expect(instanced.morphWeights, [1]);
    expect(skin.morphWeights, [1]);
    final original = skin.captureDeformation();
    tester
        .widget<Slider>(find.byKey(const ValueKey('Geometry Pose')))
        .onChanged!(1);
    await tester.pumpAndSettle();
    expect(skin.captureDeformation(), isNot(same(original)));
    final originalColors = instanced.captureInstances();
    await tester.tap(find.byKey(const ValueKey('Geometry colors')));
    await tester.pumpAndSettle();
    expect(instanced.captureInstances(), isNot(same(originalColors)));
    expect(instanced.getColor(0), isNot(instanced.getColor(1)));
    await tester.tap(find.byKey(const ValueKey('Geometry colors')));
    await tester.pumpAndSettle();
    expect(instanced.captureInstances().colors, originalColors.colors);
    for (final size in [
      const Size(390, 700),
      const Size(1100, 700),
      const Size(320, 640),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(300));
    }
    expect(
      backend.submissions,
      isNotEmpty,
      reason: switch (controller.status.value) {
        SceneFailed(:final issue) => issue.toString(),
        final state => state.toString(),
      },
    );
    expect(backend.submissions.last.scene.drawCalls, 2);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => controller.whenDisposed);
    expect(backend.closeCount, 1);
  });
}
