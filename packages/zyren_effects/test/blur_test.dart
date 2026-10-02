import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_effects/zyren_effects.dart';
import 'package:zyren_native/zyren_native.dart';

double half(int h) {
  final sign = h & 0x8000 == 0 ? 1 : -1, exp = (h >> 10) & 31, m = h & 1023;
  return sign *
      (exp == 0
          ? math.pow(2, -14) * m / 1024
          : math.pow(2, exp - 15) * (1 + m / 1024));
}

void main() {
  test(
    'native blur graphs match original TSL expressions on odd sizes and borders',
    () async {
      final fixture =
          jsonDecode(File('test/fixtures/filters.json').readAsStringSync())
              as Map<String, dynamic>;
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      try {
        for (final c in fixture['cases'] as List) {
          final inputScope = owner.createChild();
          final input = await inputScope.resources.createTexture(
            TextureDescriptor(
              width: c['width'] as int,
              height: c['height'] as int,
              format: TextureFormat.rgba32Float,
              usage: {TextureUsage.sampled, TextureUsage.copyDestination},
            ),
          );
          await inputScope.resources.writeTexture(
            input,
            Float32List.fromList(
              (c['input'] as List)
                  .cast<num>()
                  .map((v) => v.toDouble())
                  .toList(),
            ),
          );
          final blur = await TextureBlur.create(
            owner,
            input,
            kind: BlurKind.values.byName(c['kind'] as String),
            levels: 3,
          );
          await inputScope.close();
          final reader = owner.createChild();
          final readable = await reader.resources.retain(blur.output);
          final descriptor = blur.output.descriptor as TextureDescriptor;
          expect(descriptor.width, c['outputWidth']);
          expect(descriptor.height, c['outputHeight']);
          final stats = await blur.execute();
          expect(stats.dispatches, c['kind'] == 'gaussian' ? 2 : 5);
          final data = await reader.resources.readTexture(readable),
              view = ByteData.sublistView(data);
          for (var i = 0; i < (c['expected'] as List).length; i++) {
            final actual = half(view.getUint16(i * 2, Endian.little)),
                expected = (c['expected'][i] as num).toDouble();
            expect(
              actual,
              closeTo(expected, math.max(.00003, expected.abs() * .004)),
              reason: '${c['kind']} ${c['pattern']} ${c['width']} channel $i',
            );
          }
          await blur.execute();
          expect(await reader.resources.readTexture(readable), data);
          await blur.close();
          await expectLater(blur.execute(), throwsStateError);
          expect(await reader.resources.readTexture(readable), data);
          await reader.close();
          expect((await backend.resourceStats()).residentBytes, 0);
        }
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'invalid blur candidates preserve a live filter and release their scope',
    () async {
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      try {
        final input = await owner.resources.createTexture(
          TextureDescriptor(
            width: 3,
            height: 2,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.sampled, TextureUsage.copyDestination},
          ),
        );
        await owner.resources.writeTexture(input, Float32List(24));
        final live = await TextureBlur.create(
          owner,
          input,
          kind: BlurKind.surface,
          levels: 8,
        );
        final children = owner.childCount,
            bytes = (await backend.resourceStats()).residentBytes;
        for (final levels in [1, 9]) {
          await expectLater(
            TextureBlur.create(owner, input, levels: levels),
            throwsArgumentError,
          );
        }
        for (final blend in [-1.0, 1.1, double.nan]) {
          await expectLater(
            TextureBlur.create(owner, input, surfaceBlend: blend),
            throwsArgumentError,
          );
        }
        await expectLater(
          TextureBlur.create(owner, input, kernelSize: 2),
          throwsArgumentError,
        );
        expect(owner.childCount, children);
        expect((await backend.resourceStats()).residentBytes, bytes);
        expect((await live.execute()).dispatches, 15);
        await live.close();
        await owner.close();
        await expectLater(TextureBlur.create(owner, input), throwsStateError);
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test('Gaussian kernels and blur bounds reject invalid settings', () {
    for (final n in [0, 1, 2, 4, 64, 65]) {
      expect(() => GaussianKernel(n), throwsArgumentError);
    }
    final fixture =
        jsonDecode(File('test/fixtures/filters.json').readAsStringSync())
            as Map<String, dynamic>;
    for (final c in fixture['kernels'] as List) {
      final kernel = GaussianKernel(c['size'] as int);
      expect(kernel.weights.length, (c['weights'] as List).length);
      for (var i = 0; i < kernel.weights.length; i++) {
        expect(kernel.weights[i], closeTo(c['weights'][i] as num, 1e-14));
        expect(kernel.offsets[i], closeTo(c['offsets'][i] as num, 1e-14));
      }
    }
    final k = GaussianKernel(35);
    expect(k.weights.length, 9);
    expect(
      k.weights.first + 2 * k.weights.skip(1).fold<double>(0, (a, b) => a + b),
      closeTo(1, 1e-12),
    );
    expect(() => k.weights[0] = 0, throwsUnsupportedError);
  });
}
