import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial/src/clouds/frame.dart';
import 'package:zyren_geospatial/src/clouds/shadow_pass.dart';
import 'package:zyren_native/zyren_native.dart';
import 'cloud_shadow_test.dart' show constantCloudTextures;
import 'cloud_render_test.dart' show uniformClouds;

void main() {
  test(
    'stable shadow cadence preserves atlas and forces unsafe skips to refresh',
    () async {
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      final textures = await constantCloudTextures(owner);
      final pass = await CloudShadowPass.build(
        owner,
        textures,
        CloudQuality.forPreset(CloudQualityPreset.low),
        mapSize: 16,
        temporal: true,
      );
      final camera = PerspectiveCamera(
        position: const Vec3(0, 0, 6360100),
        target: const Vec3(0, 10000, 6360100),
        up: const Vec3(0, 0, 1),
        near: 1,
        far: 20000,
      );
      var sun = const Vec3(0, 0, 1);
      CloudFrameState frame() => CloudFrameState(
        camera: camera,
        worldToEcef: Mat4.identity(),
        correctedCamera: camera.position,
        sun: sun,
        aspect: 1,
        width: 16,
        height: 16,
        shadowSize: 16,
        cascadeCount: 2,
      );
      Future<void> render({
        bool valid = true,
        bool animated = false,
        double coverage = 1,
      }) => pass.render(
        uniformClouds(coverage),
        CloudAppearance(),
        frame(),
        historyValid: valid,
        cadence: 4,
        animated: animated,
      );
      try {
        await render(valid: false);
        final initial = await pass.temporal!.scope.resources.readTexture(
          pass.atlas!,
        );
        for (var i = 0; i < 3; i++) {
          await render();
          expect(pass.updateReason, 'reused');
          expect(pass.updated, false);
          expect(
            await pass.temporal!.scope.resources.readTexture(pass.atlas!),
            initial,
          );
        }
        await render();
        expect(pass.updateReason, 'cadence');
        expect(pass.updated, true);
        await render(animated: true);
        expect(pass.updateReason, 'animatedMedia');
        await render(coverage: 0);
        expect(pass.updateReason, 'mediaChanged');
        await render(valid: false, coverage: 0);
        expect(pass.updateReason, 'historyInvalid');
        final clear = ByteData.sublistView(
          await pass.temporal!.scope.resources.readTexture(pass.atlas!),
        );
        for (var i = 0; i < clear.lengthInBytes ~/ 16; i++) {
          expect(clear.getFloat32(i * 16 + 4, Endian.little), 0);
        }
        camera.position += const Vec3(100, 0, 0);
        camera.target += const Vec3(100, 0, 0);
        await render(coverage: 0);
        expect(pass.updateReason, 'cascadeChanged');
        sun = const Vec3(.1, 0, 1).normalized();
        await render(coverage: 0);
        expect(pass.updateReason, 'cascadeChanged');
        await render(valid: false, coverage: 0);
        await render(coverage: 0);
        expect(pass.updateReason, 'reused');
      } finally {
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );
}
