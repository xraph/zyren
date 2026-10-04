import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'volume environment lighting survives auxiliary capture without main effects',
    () async {
      final backend = await NativeBackend.create();
      final resources = backend.createResourceScope();
      final shaders = backend.createShaderCompiler();
      final graphs = backend.createGraphCompiler();
      final probes = await ReflectionProbes.create(backend);
      try {
        final source = await resources.createTexture(
          TextureDescriptor(
            width: 2,
            height: 1,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.sampled, TextureUsage.copyDestination},
          ),
        );
        await resources.writeTexture(
          source,
          Float32List.fromList([2, 2, 2, 1, 2, 2, 2, 1]).buffer.asUint8List(),
        );
        final volume = await VolumeEnvironmentMap.generate(
          resources: resources,
          shaders: shaders,
          graphs: graphs,
          source: source,
          resolution: 4,
          roughnessLevels: 2,
          brdfSize: 16,
          samples: 64,
        );
        final scene = Scene()
          ..ambient = 0
          ..renderSettings = RenderSettings(
            environment: volume,
            bloom: BloomSettings(),
          );
        scene.add(
          Mesh(
            BoxGeometry(width: 8, height: 8, depth: 8),
            StandardMaterial(roughness: 1),
          ),
        );
        await probes.update(
          ReflectionProbeDescriptor(
            id: 0,
            position: Vec3.zero,
            bounds: Bounds3(-Vec3.one, Vec3.one),
            faceSize: 16,
            quality: const EnvironmentQuality(
              specularWidth: 16,
              diffuseWidth: 16,
              brdfSize: 16,
              samples: 64,
            ),
          ),
          scene: scene,
          contentRevision: 1,
        );
        while (probes.pending) {
          await probes.advance();
        }
        expect(probes.lastCapture!.sharedEnergyLutBytes, 0);
        expect(scene.renderSettings.bloom, isNotNull);
        final map = probes.environment(0)!.map;
        final bytes = ByteData.sublistView(
          await resources.readTexture(await resources.retain(map.specular)),
        );
        expect(bytes.getUint16(0, Endian.little), greaterThan(0));
        scene.reflectionProbes = probes;
        await backend.render(
          FrameSubmission.capture(
            scene: scene,
            camera: PerspectiveCamera(),
            size: PhysicalSize(16, 16),
          ),
        );
        expect(
          (await backend.inspectGpu())
              .frameProfile!
              .passes['energyLut']
              ?.executed,
          isFalse,
        );
      } finally {
        await probes.close();
        await graphs.close();
        await shaders.close();
        await resources.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
