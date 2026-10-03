import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/src/clouds/volume_mips.dart';

void main() {
  for (final size in [8, 7]) {
    test(
      'native volume mips preserve base detail and mean at size $size',
      () async {
        final backend = await NativeBackend.create();
        final scope = GpuScope.fromBackend(backend);
        try {
          final original = Float32List.fromList([
            for (var z = 0; z < size; z++)
              for (var y = 0; y < size; y++)
                for (var x = 0; x < size; x++) ((x + y + z) % 2).toDouble(),
          ]);
          final descriptor = TextureDescriptor(
            width: size,
            height: size,
            depth: size,
            mipLevels: size.bitLength,
            dimension: TextureDimension.d3,
            format: TextureFormat.r32Float,
            usage: {
              TextureUsage.sampled,
              TextureUsage.storage,
              TextureUsage.copySource,
              TextureUsage.copyDestination,
            },
          );
          final volume = await scope.resources.createTexture(descriptor);
          await scope.resources.writeTexture(volume, original);
          await generateCloudVolumeMips(scope, volume);
          expect(
            await scope.resources.readTexture(volume),
            original.buffer.asUint8List(),
          );
          final mean = original.reduce((a, b) => a + b) / original.length;
          for (var mip = 1; mip < descriptor.mipLevels; mip++) {
            final data = ByteData.sublistView(
              await scope.resources.readTexture(volume, mipLevel: mip),
            );
            final count = math.pow(math.max(1, size >> mip), 3).toInt();
            var sum = 0.0;
            for (var index = 0; index < count; index++) {
              final value = data.getFloat32(index * 4, Endian.little);
              expect(value, inInclusiveRange(0, 1));
              if (size.isEven) expect(value, closeTo(.5, 1e-6));
              sum += value;
            }
            expect(sum / count, closeTo(mean, 1e-6));
          }
        } finally {
          await scope.close();
          expect((await backend.resourceStats()).residentBytes, 0);
          await backend.close();
        }
      },
    );
  }
}
