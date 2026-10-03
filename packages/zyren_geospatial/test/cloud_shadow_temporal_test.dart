import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial/src/clouds/shadow_temporal.dart';
import 'package:zyren_geospatial/src/clouds/frame.dart';
import 'package:zyren_geospatial/src/clouds/media_uniforms.dart';
import 'package:zyren_native/zyren_native.dart';
import 'cloud_render_test.dart' show uniformClouds;

void main() {
  test(
    'shadow history uses source alpha and keeps cascade edges separate',
    () async {
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      try {
        final raw = await owner.resources.createTexture(
          TextureDescriptor(
            width: 32,
            height: 16,
            format: TextureFormat.rgba32Float,
          ),
        );
        final media = await owner.resources.createBuffer(
          BufferDescriptor(
            size: 400,
            usage: {BufferUsage.uniform, BufferUsage.copyDestination},
          ),
        );
        final frame = await owner.resources.createBuffer(
          BufferDescriptor(
            size: 832,
            usage: {BufferUsage.uniform, BufferUsage.copyDestination},
          ),
        );
        await owner.resources.writeBuffer(
          media,
          cloudMediaUniforms(uniformClouds(1), CloudAppearance()),
        );
        final camera = PerspectiveCamera(
          position: const Vec3(0, 0, 6360100),
          target: const Vec3(0, 1000, 6360100),
          up: const Vec3(0, 0, 1),
          near: 1,
          far: 20000,
        );
        final state = CloudFrameState(
          camera: camera,
          worldToEcef: Mat4.identity(),
          correctedCamera: camera.position,
          sun: const Vec3(0, 0, 1),
          aspect: 1,
          width: 16,
          height: 16,
          shadowSize: 16,
          cascadeCount: 2,
        );
        await owner.resources.writeBuffer(frame, state.data);
        final pass = await CloudShadowTemporal.build(
          owner,
          raw,
          media,
          frame,
          CloudQuality.forPreset(CloudQualityPreset.low),
        );
        Future<void> fill(bool initial) async => owner.resources.writeTexture(
          raw,
          Float32List.fromList([
            for (var y = 0; y < 16; y++)
              for (var x = 0; x < 32; x++) ...[
                10,
                x >= 16
                    ? .8
                    : initial
                    ? .1
                    : y == 8 && (x == 8 || x == 15)
                    ? .4
                    : 0,
                .2,
                .3,
              ],
          ]).buffer.asUint8List(),
        );
        await fill(true);
        await pass.render(state, valid: false);
        pass.presented();
        await fill(false);
        await pass.render(state, valid: true);
        final bytes = ByteData.sublistView(
          await pass.scope.resources.readTexture(pass.output),
        );
        double g(int x, int y) =>
            bytes.getFloat32(((y * 32 + x) * 4 + 1) * 4, Endian.little);
        expect(g(8, 8), closeTo(.103, .0001));
        expect(g(15, 8), closeTo(.103, .0001));
        expect(g(16, 8), closeTo(.8, .0001));
        await pass.render(state, valid: false);
        final reset = ByteData.sublistView(
          await pass.scope.resources.readTexture(pass.output),
        );
        expect(
          reset.getFloat32(((8 * 32 + 8) * 4 + 1) * 4, Endian.little),
          closeTo(.4, 1e-6),
        );
      } finally {
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );
}
