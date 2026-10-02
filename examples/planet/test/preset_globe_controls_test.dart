import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:planet/geospatial_presets.dart';
import 'package:planet/preset_globe_controls.dart';

void main() {
  test(
    'preset switches reset the local frame and delay surface clearance',
    () async {
      final camera = PerspectiveCamera();
      GoogleTilesPreset.manhattan.applyCamera(camera);
      final plugin = PresetGlobeControlsPlugin();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: camera,
        rendererFactory: () async => _EmptyRenderer(),
        plugins: [GeospatialPlugin(), plugin],
      );
      try {
        final controls = plugin.controls!;
        controls.viewport = const ViewportMetrics(800, 600);
        for (final preset in [
          GoogleTilesPreset.fuji,
          GoogleTilesPreset.manhattan,
        ]) {
          controls.dragInertia = const Vec3(100, 200, 300);
          controls.zoomDelta = 300;
          preset.applyCamera(camera);
          plugin.resetForPreset();
          final position = camera.position, target = camera.target;
          for (var i = 0; i < 5; i++) {
            controls.update(1 / 60);
          }
          expect(camera.position.distanceTo(position), lessThan(1e-6));
          expect(camera.target.distanceTo(target), lessThan(1e-6));
          expect(controls.adjustHeight, isFalse);
          expect(
            controls.up.distanceTo(controls.getCameraUpDirection()),
            lessThan(1e-12),
          );
          controls.handlePointer(
            ScenePointerEvent(
              point: const ViewportPoint(400, 300),
              phase: ScenePointerPhase.down,
              kind: ScenePointerKind.mouse,
              buttons: 1,
            ),
          );
          expect(controls.adjustHeight, isTrue);
          controls.cancel();
        }
      } finally {
        await engine.dispose();
      }
    },
  );
}

final class _EmptyRenderer implements SceneRenderer {
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
    name: 'control fixture',
    features: {RenderFeature.rgbaReadback},
    maxDimension: 64,
  );
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) async => RenderedFrame(Uint8List(width * height * 4), width, height);
  @override
  Future<void> dispose() async {}
}
