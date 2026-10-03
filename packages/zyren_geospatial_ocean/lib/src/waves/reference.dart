import 'dart:math' as math;
import 'dart:typed_data';

/// Independent O(N^4) inverse DFT oracle, restricted to grids of at most 32.
/// Positive exponential, row-major z/x, interleaved complex, one 1/N^2 factor.
/// Frequencies use wrapped centered order: [0,1,...,N/2-1,-N/2,...,-1].
Float64List inverseDft2(Float64List complex, int size) {
  if (size < 2 ||
      size > 32 ||
      (size & (size - 1)) != 0 ||
      complex.length != 2 * size * size ||
      complex.any((v) => !v.isFinite)) {
    throw ArgumentError(
      'The DFT oracle requires a finite, bounded complex grid.',
    );
  }
  final output = Float64List(complex.length), normalization = 1 / (size * size);
  for (var z = 0; z < size; z++) {
    for (var x = 0; x < size; x++) {
      var real = 0.0, imaginary = 0.0;
      for (var kz = 0; kz < size; kz++) {
        for (var kx = 0; kx < size; kx++) {
          final i = 2 * (kz * size + kx),
              angle = 2 * math.pi * (kx * x + kz * z) / size;
          final c = math.cos(angle), s = math.sin(angle);
          real += complex[i] * c - complex[i + 1] * s;
          imaginary += complex[i] * s + complex[i + 1] * c;
        }
      }
      final i = 2 * (z * size + x);
      output[i] = real * normalization;
      output[i + 1] = imaginary * normalization;
    }
  }
  return output.asUnmodifiableView();
}
