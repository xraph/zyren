import 'package:test/test.dart';
import 'package:zyren/zyren.dart';

void main() {
  test('probe dimensions and each integration job have explicit limits', () {
    ReflectionProbeDescriptor make(
      int n, {
      EnvironmentQuality quality = const EnvironmentQuality(),
    }) => ReflectionProbeDescriptor(
      id: 1,
      position: Vec3.zero,
      bounds: Bounds3(-Vec3.one, Vec3.one),
      faceSize: n,
      quality: quality,
    );
    for (final n in [16, 32, 64, 128, 256]) {
      expect(make(n).faceSize, n);
    }
    for (final n in [0, 15, 17, 257, 512]) {
      expect(() => make(n), throwsArgumentError);
    }
    expect(
      () => make(
        32,
        quality: const EnvironmentQuality(specularWidth: 1024, samples: 64),
      ),
      throwsArgumentError,
    );
    expect(
      () => make(
        32,
        quality: const EnvironmentQuality(brdfSize: 512, samples: 128),
      ),
      throwsArgumentError,
    );
    expect(
      make(
        16,
        quality: const EnvironmentQuality(brdfSize: 512, samples: 64),
      ).quality.brdfSize,
      512,
    );
  });
}
