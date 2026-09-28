import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shader_lab/pbr.dart';
import '../../../packages/flutter_gpu3d/test/support/backend_fake.dart';
import '../../../packages/flutter_gpu3d/test/support/fakes.dart';

class PbrBackend extends FakeBackend {
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'PBR fixture',
    features: {
      RenderFeature.rgbaReadback,
      RenderFeature.indexedMeshes,
      RenderFeature.standardMaterials,
    },
    limits: DeviceLimits(
      maxTextureDimension2D: 2048,
      maxGeometryBytes: 1000000,
      maxPunctualLights: 16,
      maxHemisphereLights: 4,
    ),
  );
}

void main() {
  testWidgets(
    'PBR grid controls preserve a usable native canvas at narrow widths',
    (tester) async {
      final backend = PbrBackend();
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        PbrLabApp(
          runtime: SceneRuntime(
            backendFactory: () async => backend,
            presenterFactory: () => TestPresenter('PBR frame', backend.events),
          ),
          presentation: PresentationPolicy.readbackOnly,
        ),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      expect(backend.submissions.last.scene.drawCalls, 12);
      final light = controller.scene.children
          .whereType<DirectionalLight>()
          .single;
      final materials = controller.scene.children
          .whereType<Group>()
          .single
          .children
          .whereType<Mesh>();
      expect(
        (materials.first.material as StandardMaterial).normalMap,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('Textures')));
      await tester.pumpAndSettle();
      expect((materials.first.material as StandardMaterial).normalMap, isNull);
      final initial = light.intensity;
      await tester.drag(
        find.byKey(const ValueKey('Light')),
        const Offset(-40, 0),
      );
      await tester.pumpAndSettle();
      expect(light.intensity, lessThan(initial));
      for (final size in [const Size(390, 700), const Size(1100, 700)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(SceneView)).height, greaterThan(250));
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => controller.whenDisposed);
      expect(backend.closeCount, 1);
    },
  );
}
