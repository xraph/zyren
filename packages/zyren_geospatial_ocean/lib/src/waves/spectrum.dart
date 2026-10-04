import 'dart:math' as math;
import 'dart:typed_data';
import 'sea_state.dart';

/// Angular frequency in radians/second. A null depth means deep water.
double oceanDispersion(
  double waveNumber, {
  double gravity = 9.81,
  double? depthMetres,
}) {
  if (!waveNumber.isFinite ||
      waveNumber < 0 ||
      !gravity.isFinite ||
      gravity <= 0 ||
      (depthMetres != null && (!depthMetres.isFinite || depthMetres <= 0))) {
    throw ArgumentError(
      'Dispersion requires nonnegative k, positive gravity and depth.',
    );
  }
  final kd = depthMetres == null ? double.infinity : waveNumber * depthMetres;
  // The series avoids subtracting nearly equal values in very shallow water.
  final tanh = kd < 1e-4
      ? kd * (1 - kd * kd / 3 + 2 * kd * kd * kd * kd / 15)
      : kd > 20
      ? 1.0
      : (math.exp(2 * kd) - 1) / (math.exp(2 * kd) + 1);
  final result = math.sqrt(gravity * waveNumber * tanh);
  if (!result.isFinite) {
    throw ArgumentError('Dispersion exceeds finite numeric range.');
  }
  return result;
}

int oceanFrequencyIndex(int index, int size) =>
    index < size ~/ 2 ? index : index - size;

/// Independent Gaussian draws use SplitMix64 and Box-Muller on the CPU.
/// Coefficients include N^2 so the single normalized inverse transform produces
/// physical metres. Nyquist rows/columns are zero to preserve real derivatives.
Float64List seedSpectrum(OceanSeaState state, int bandIndex) {
  RangeError.checkValidIndex(bandIndex, state.bands);
  final size = state.canonicalResolution, band = state.bands[bandIndex];
  final step = 2 * math.pi / band.patchMetres,
      out = Float64List(2 * size * size);
  for (var z = 0; z < size; z++) {
    for (var x = 0; x < size; x++) {
      if ((x == 0 && z == 0) || x == size ~/ 2 || z == size ~/ 2) continue;
      final nx = oceanFrequencyIndex(x, size),
          nz = oceanFrequencyIndex(z, size);
      final kx = nx * step, kz = nz * step, k = math.sqrt(kx * kx + kz * kz);
      final energy = state.spectrum.energy(
        kx,
        kz,
        band,
        gravity: state.gravity,
      );
      if (!energy.isFinite || energy < 0) {
        throw ArgumentError('Spectrum density must be finite and nonnegative.');
      }
      final scale =
          math.sqrt(
            energy * state.energyWeight(bandIndex, k) * step * step / 2,
          ) *
          size *
          size;
      // Fixed bit layout uses signed indices biased by 32768, not grid indices.
      final coordinates =
          (BigInt.from(bandIndex + 1) << 32) |
          (BigInt.from(nx + 32768) << 16) |
          BigInt.from(nz + 32768);
      final key =
          _splitMix64(BigInt.from(state.seed)) ^ _splitMix64(coordinates);
      final h = _splitMix64(key), h2 = _splitMix64(h);
      final u = ((h >> 12).toDouble() + .5) / 4503599627370496.0;
      final v = ((h2 >> 12).toDouble() + .5) / 4503599627370496.0;
      final radius = math.sqrt(-2 * math.log(u)), phase = 2 * math.pi * v;
      final i = 2 * (z * size + x);
      out[i] = radius * math.cos(phase) * scale;
      out[i + 1] = radius * math.sin(phase) * scale;
      if (!out[i].isFinite || !out[i + 1].isFinite) {
        throw ArgumentError('Spectrum coefficients exceeded finite range.');
      }
    }
  }
  return out.asUnmodifiableView();
}

final _mask64 = (BigInt.one << 64) - BigInt.one;
final _mixIncrement = BigInt.parse('9e3779b97f4a7c15', radix: 16);
final _mixFirst = BigInt.parse('bf58476d1ce4e5b9', radix: 16);
final _mixSecond = BigInt.parse('94d049bb133111eb', radix: 16);
BigInt _splitMix64(BigInt value) {
  var z = (value + _mixIncrement) & _mask64;
  z = ((z ^ (z >> 30)) * _mixFirst) & _mask64;
  z = ((z ^ (z >> 27)) * _mixSecond) & _mask64;
  return (z ^ (z >> 31)) & _mask64;
}

/// Convenience for one evaluation. Keep OceanSpectrum for repeated sampling.
Float64List evolveSpectrum(OceanSeaState state, int band, double seconds) =>
    OceanSpectrum(state).evolve(band, seconds);

final class OceanReferenceSample {
  final double height,
      displacementX,
      displacementZ,
      slopeX,
      slopeZ,
      velocityX,
      velocityY,
      velocityZ,
      displacementXX,
      displacementXZ,
      displacementZX,
      displacementZZ;
  const OceanReferenceSample({
    required this.height,
    required this.displacementX,
    required this.displacementZ,
    required this.slopeX,
    required this.slopeZ,
    required this.velocityX,
    required this.velocityY,
    required this.velocityZ,
    required this.displacementXX,
    required this.displacementXZ,
    required this.displacementZX,
    required this.displacementZZ,
  });
  double get horizontalJacobian =>
      (1 + displacementXX) * (1 + displacementZZ) -
      displacementXZ * displacementZX;
}

/// Canonical coefficients are seeded once. Evaluation never changes the state.
final class OceanSpectrum {
  final OceanSeaState state;
  late final List<Float64List> coefficients = List.unmodifiable([
    for (var i = 0; i < state.bands.length; i++) seedSpectrum(state, i),
  ]);
  late final List<Float64List> frequencies = List.unmodifiable([
    for (final band in state.bands) _frequencies(band),
  ]);
  OceanSpectrum(this.state);
  Float64List _frequencies(OceanWaveBand band) {
    final size = state.canonicalResolution,
        step = 2 * math.pi / band.patchMetres;
    final out = Float64List(size * size);
    for (var z = 0; z < size; z++) {
      for (var x = 0; x < size; x++) {
        final kx = oceanFrequencyIndex(x, size) * step,
            kz = oceanFrequencyIndex(z, size) * step;
        out[z * size + x] = oceanDispersion(
          math.sqrt(kx * kx + kz * kz),
          gravity: state.gravity,
          depthMetres: band.depthMetres,
        );
      }
    }
    return out.asUnmodifiableView();
  }

  void _time(double seconds) {
    if (!seconds.isFinite || seconds.abs() > 1e12) {
      throw ArgumentError(
        'Wave time must be finite and within 1e12 seconds of its epoch.',
      );
    }
  }

  (double, double, double, double) _term(
    int band,
    int x,
    int z,
    double seconds,
  ) {
    final size = state.canonicalResolution, h = coefficients[band];
    final i = 2 * (z * size + x),
        j = 2 * (((size - z) % size) * size + (size - x) % size);
    if (h[i] == 0 && h[i + 1] == 0 && h[j] == 0 && h[j + 1] == 0) {
      return (0, 0, 0, 0);
    }
    // Negative time phase makes positive k travel toward the wind heading.
    final omega = -frequencies[band][z * size + x];
    final phase = omega == 0 ? 0.0 : (seconds % (2 * math.pi / -omega)) * omega;
    final c = math.cos(phase), s = math.sin(phase);
    final sumR = h[i] + h[j], sumI = h[i + 1] + h[j + 1];
    final deltaR = h[i] - h[j], deltaI = h[i + 1] - h[j + 1];
    return (
      sumR * c - sumI * s,
      deltaR * s + deltaI * c,
      -omega * (sumR * s + sumI * c),
      omega * (deltaR * c - deltaI * s),
    );
  }

  Float64List evolve(int band, double seconds) {
    RangeError.checkValidIndex(band, state.bands);
    _time(seconds);
    final size = state.canonicalResolution, out = Float64List(2 * size * size);
    for (var z = 0; z < size; z++) {
      for (var x = 0; x < size; x++) {
        final (real, imaginary, _, _) = _term(band, x, z, seconds);
        final i = 2 * (z * size + x);
        out[i] = real;
        out[i + 1] = imaginary;
      }
    }
    return out.asUnmodifiableView();
  }

  /// Canonical complex height and time derivative with the same normalization.
  ({Float64List height, Float64List velocity}) evolveDifferential(
    int band,
    double seconds,
  ) {
    RangeError.checkValidIndex(band, state.bands);
    _time(seconds);
    final size = state.canonicalResolution;
    final height = Float64List(2 * size * size),
        velocity = Float64List(2 * size * size);
    for (var z = 0; z < size; z++) {
      for (var x = 0; x < size; x++) {
        final (real, imaginary, vr, vi) = _term(band, x, z, seconds);
        final i = 2 * (z * size + x);
        height[i] = real;
        height[i + 1] = imaginary;
        velocity[i] = vr;
        velocity[i + 1] = vi;
      }
    }
    return (
      height: height.asUnmodifiableView(),
      velocity: velocity.asUnmodifiableView(),
    );
  }

  /// Exact small-fixture reconstruction at material coordinates in metres.
  /// Choppy displacement is returned separately; this does not invert it.
  OceanReferenceSample reference(
    double x,
    double z,
    double seconds, {
    int maxCoefficients = 4096,
  }) {
    _time(seconds);
    final size = state.canonicalResolution;
    if (!x.isFinite ||
        !z.isFinite ||
        x.abs() > 1e12 ||
        z.abs() > 1e12 ||
        maxCoefficients < 1 ||
        maxCoefficients > 8192 ||
        state.bands.length * size * size > maxCoefficients) {
      throw ArgumentError(
        'Reference reconstruction exceeds its coordinate or work budget.',
      );
    }
    var height = state.meanLevel,
        dx = 0.0,
        dz = 0.0,
        sx = 0.0,
        sz = 0.0,
        vx = 0.0,
        vy = 0.0,
        vz = 0.0,
        dxx = 0.0,
        dxz = 0.0,
        dzx = 0.0,
        dzz = 0.0;
    final normalization = 1 / (size * size);
    for (var band = 0; band < state.bands.length; band++) {
      final b = state.bands[band], step = 2 * math.pi / b.patchMetres;
      for (var iz = 0; iz < size; iz++) {
        for (var ix = 0; ix < size; ix++) {
          final kx = oceanFrequencyIndex(ix, size) * step,
              kz = oceanFrequencyIndex(iz, size) * step;
          final k = math.sqrt(kx * kx + kz * kz);
          if (k == 0) continue;
          final (hr, hi, tr, ti) = _term(band, ix, iz, seconds);
          final angle = kx * (x % b.patchMetres) + kz * (z % b.patchMetres),
              c = math.cos(angle),
              s = math.sin(angle);
          final r = (hr * c - hi * s) * normalization,
              im = (hr * s + hi * c) * normalization;
          final vr = (tr * c - ti * s) * normalization,
              vi = (tr * s + ti * c) * normalization;
          final ax = b.choppiness * kx / k, az = b.choppiness * kz / k;
          height += r;
          sx -= kx * im;
          sz -= kz * im;
          dx += ax * im;
          dz += az * im;
          vx += ax * vi;
          vy += vr;
          vz += az * vi;
          dxx += ax * kx * r;
          dxz += ax * kz * r;
          dzx += az * kx * r;
          dzz += az * kz * r;
        }
      }
    }
    return OceanReferenceSample(
      height: height,
      displacementX: dx,
      displacementZ: dz,
      slopeX: sx,
      slopeZ: sz,
      velocityX: vx,
      velocityY: vy,
      velocityZ: vz,
      displacementXX: dxx,
      displacementXZ: dxz,
      displacementZX: dzx,
      displacementZZ: dzz,
    );
  }
}
