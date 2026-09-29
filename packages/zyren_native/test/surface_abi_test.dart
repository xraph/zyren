import 'package:zyren_native/surfaces.dart';
import 'package:test/test.dart';

void main() {
  test('generated ABI preserves identity, epochs and request errors', () {
    final registry = NativeSurfaces();
    final first = registry.reserve(width: 63, height: 47, memoryLimit: 40000);
    expect(first.runtimeToken, registry.runtimeToken);
    expect(first.state, NativeSurfaceState.creating);
    expect(first.epoch, 1);
    try {
      expect(
        () => registry.resize(first, width: 300, height: 300),
        throwsA(
          isA<NativeSurfaceException>().having((e) => e.code, 'code', 10),
        ),
      );
      final resized = registry.resize(first, width: 81, height: 59);
      expect(resized.key, first.key);
      expect((resized.width, resized.height, resized.epoch), (81, 59, 2));
      expect(
        () => registry.resize(first, width: 32, height: 32),
        throwsA(isA<NativeSurfaceException>().having((e) => e.code, 'code', 3)),
      );
      expect(registry.close(resized).state, NativeSurfaceState.closed);
      expect(registry.close(resized).state, NativeSurfaceState.closed);
    } finally {
      registry.close(first);
    }
    final replacement = registry.reserve(width: 32, height: 32);
    try {
      expect(replacement.key, isNot(first.key));
      expect(
        () => registry.close(first),
        throwsA(isA<NativeSurfaceException>().having((e) => e.code, 'code', 2)),
      );
    } finally {
      registry.close(replacement);
    }
  });

  test('Dart validates unsigned arguments before FFI conversion', () {
    final registry = NativeSurfaces();
    for (final size in [-1, 0, 4097, 0x100000001]) {
      expect(
        () => registry.reserve(width: size, height: 1),
        throwsArgumentError,
      );
    }
    expect(
      () => registry.reserve(width: 1, height: 1, bufferLimit: 4),
      throwsArgumentError,
    );
    expect(
      () => registry.reserve(width: 1, height: 1, maxInFlight: 3),
      throwsArgumentError,
    );
  });
}
