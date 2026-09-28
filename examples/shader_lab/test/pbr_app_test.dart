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
      RenderFeature.hdrColor,
      RenderFeature.shadows,
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
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 62, bottom: 34);
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        PbrLabApp(
          runtime: SceneRuntime(
            backendFactory: () async => backend,
            presenterFactory: () => TestPresenter('PBR frame', backend.events),
          ),
          presentation: PresentationPolicy.readbackOnly,
          environmentLighting: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(250));
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      expect(backend.submissions.last.scene.drawCalls, 13);
      expect(controller.colorPipeline?.toneMapping, ToneMapping.acesFilmic);
      final initialExposure = controller.colorPipeline!.exposure;
      await tester.drag(
        find.byKey(const ValueKey('Exposure')),
        const Offset(-40, 0),
      );
      await tester.pumpAndSettle();
      expect(controller.colorPipeline!.exposure, lessThan(initialExposure));
      expect(
        backend.submissions.last.colorPipeline,
        same(controller.colorPipeline),
      );
      final light = controller.scene.children
          .whereType<DirectionalLight>()
          .single;
      expect(light.shadow, isNotNull);
      await tester.tap(find.byKey(const ValueKey('Shadows')));
      await tester.pumpAndSettle();
      expect(light.shadow, isNull);
      await tester.tap(find.byKey(const ValueKey('Shadows')));
      await tester.pumpAndSettle();
      expect(backend.submissions.last.shadows.views.length, 3);
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
      await tester.binding.setSurfaceSize(const Size(320, 640));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('LightingControls')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Environment').last);
      await tester.pumpAndSettle();
      for (final label in ['Sky', 'Rotation']) {
        final slider = find.byKey(ValueKey(label));
        final before = tester.widget<Slider>(slider).value;
        await tester.drag(slider, const Offset(40, 0));
        await tester.pumpAndSettle();
        expect(tester.widget<Slider>(slider).value, greaterThan(before));
      }
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(250));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => controller.whenDisposed);
      expect(backend.closeCount, 1);
    },
  );
}
