import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'support/brdf_reference.dart';
import 'support/environment_checks.dart' show constantEnvironment, halfAt;

void main() {
  test(
    'both environment LUT families share endpoint Schlick energy data',
    () async {
      final backend = await NativeBackend.create();
      final resources = backend.createResourceScope();
      final shaders = backend.createShaderCompiler();
      final graphs = backend.createGraphCompiler();
      EnvironmentMap? conventional;
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
          Float32List.fromList([1, 1, 1, 1, 1, 1, 1, 1]).buffer.asUint8List(),
        );
        final volume = await VolumeEnvironmentMap.generate(
          resources: resources,
          shaders: shaders,
          graphs: graphs,
          source: source,
          resolution: 4,
          roughnessLevels: 2,
          brdfSize: 32,
          samples: 1024,
        );
        conventional = await EnvironmentMap.fromEquirectangular(
          constantEnvironment(1, 1, 1),
          resources: resources,
          quality: const EnvironmentQuality(
            specularWidth: 16,
            diffuseWidth: 16,
            brdfSize: 32,
            samples: 1024,
          ),
        );
        final first = await resources.readTexture(volume.brdf);
        final second = await resources.readTexture(
          await resources.retain(conventional.brdf),
        );
        expect(first, orderedEquals(second));
        final bytes = ByteData.sublistView(first);
        for (final (x, y) in [
          (0, 0),
          (31, 0),
          (0, 31),
          (1, 31),
          (2, 31),
          (31, 31),
          (3, 15),
          (15, 15),
          (31, 15),
        ]) {
          final (a, b) = referenceDirectionalEnergy(
            math.max(x / 31, 1e-8),
            y / 31,
          );
          expect(
            halfAt(bytes, (y * 32 + x) * 8),
            closeTo(a, .012),
            reason: 'A at ($x,$y)',
          );
          expect(
            halfAt(bytes, (y * 32 + x) * 8 + 2),
            closeTo(b, .012),
            reason: 'B at ($x,$y)',
          );
        }
      } finally {
        await conventional?.close();
        await graphs.close();
        await shaders.close();
        await resources.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
