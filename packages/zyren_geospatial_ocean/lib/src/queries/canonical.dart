import 'dart:math' as math;
import 'dart:typed_data';
import '../waves/sea_state.dart';
import '../waves/spectrum.dart';

/// Absolute spectral envelopes at an evaluated time, in metres and seconds.
final class OceanCanonicalEnvelope {
  final double height,
      displacement,
      slope,
      displacementGradient,
      heightHessian,
      displacementHessian,
      velocity,
      velocityGradient;
  const OceanCanonicalEnvelope(
    this.height,
    this.displacement,
    this.slope,
    this.displacementGradient,
    this.heightHessian,
    this.displacementHessian,
    this.velocity, {
    required this.velocityGradient,
  });
}

/// Prepared canonical state for one fixed chart. Construct and evolve in a worker.
final class OceanCanonicalField {
  final OceanSeaState state;
  final int maxModes, maxLogicalBytes;
  int get logicalWorkBytes =>
      state.canonicalResolution *
      state.canonicalResolution *
      (120 * state.bands.length + 32);
  late final OceanSpectrum _spectrum = OceanSpectrum(state);
  OceanCanonicalField(
    this.state, {
    required this.maxModes,
    this.maxLogicalBytes = 128 * 1024 * 1024,
  }) {
    if (maxModes < 1 ||
        maxModes > 2097152 ||
        state.canonicalResolution *
                state.canonicalResolution *
                state.bands.length >
            maxModes) {
      throw ArgumentError('Canonical wave work exceeds its mode budget.');
    }
    if (maxLogicalBytes < 1 ||
        maxLogicalBytes > 1024 * 1024 * 1024 ||
        logicalWorkBytes > maxLogicalBytes) {
      throw ArgumentError('Canonical field exceeds its logical memory budget.');
    }
  }
  OceanCanonicalSnapshot at(double seconds) {
    if (!seconds.isFinite || seconds.abs() > 1e12) {
      throw ArgumentError('Invalid canonical wave time.');
    }
    final size = state.canonicalResolution, normalization = 1 / (size * size);
    final values = Float64List(12 * size * size * state.bands.length);
    var used = 0;
    var height = 0.0,
        displacement = 0.0,
        slope = 0.0,
        dg = 0.0,
        hh = 0.0,
        dh = 0.0,
        velocity = 0.0,
        velocityGradient = 0.0;
    for (var band = 0; band < state.bands.length; band++) {
      final b = state.bands[band],
          evolved = _spectrum.evolveDifferential(band, seconds);
      final step = 2 * math.pi / b.patchMetres;
      for (var z = 0; z < size; z++) {
        for (var x = 0; x < size; x++) {
          final i = 2 * (z * size + x),
              hr = evolved.height[i] * normalization,
              hi = evolved.height[i + 1] * normalization,
              vr = evolved.velocity[i] * normalization,
              vi = evolved.velocity[i + 1] * normalization;
          if (hr == 0 && hi == 0 && vr == 0 && vi == 0) continue;
          final nx = oceanFrequencyIndex(x, size),
              nz = oceanFrequencyIndex(z, size),
              kx = nx * step,
              kz = nz * step,
              k = math.sqrt(kx * kx + kz * kz);
          if (k == 0) continue;
          final ax = b.choppiness * kx / k, az = b.choppiness * kz / k;
          values.setRange(used, used + 12, [
            hr,
            hi,
            vr,
            vi,
            kx,
            kz,
            ax,
            az,
            nx.toDouble(),
            nz.toDouble(),
            band.toDouble(),
            0,
          ]);
          used += 12;
          final amplitude = math.sqrt(hr * hr + hi * hi),
              choppy = b.choppiness * amplitude;
          height += amplitude;
          displacement += choppy;
          slope += amplitude * k;
          dg += choppy * k;
          hh += amplitude * k * k;
          dh += choppy * k * k;
          final temporal = (1 + b.choppiness) * math.sqrt(vr * vr + vi * vi);
          velocity += temporal;
          velocityGradient += temporal * k;
        }
      }
    }
    if (![
          height,
          displacement,
          slope,
          dg,
          hh,
          dh,
          velocity,
          velocityGradient,
        ].every((v) => v.isFinite) ||
        values.any((v) => !v.isFinite)) {
      throw ArgumentError(
        'Canonical wave fields exceed the finite numerical range.',
      );
    }
    return OceanCanonicalSnapshot._(
      state,
      seconds,
      values.buffer.asFloat64List(0, used).asUnmodifiableView(),
      OceanCanonicalEnvelope(
        height,
        displacement,
        slope,
        dg,
        hh,
        dh,
        velocity,
        velocityGradient: velocityGradient,
      ),
    );
  }
}

/// Twelve scalars per active mode: h, dh/dt (complex), k, choppy direction,
/// integer frequency pair, band index and padding. Coefficients are normalized.
final class OceanCanonicalSnapshot {
  final OceanSeaState state;
  final double seconds;
  final Float64List modes;
  final OceanCanonicalEnvelope envelope;
  const OceanCanonicalSnapshot._(
    this.state,
    this.seconds,
    this.modes,
    this.envelope,
  );
  String get seaStateRevision => state.revision;
  int get modeCount => modes.length ~/ 12;
  OceanReferenceSample sample(double x, double z) {
    if (!x.isFinite || !z.isFinite || x.abs() > 1e12 || z.abs() > 1e12) {
      throw ArgumentError('Canonical coordinates must be finite and bounded.');
    }
    final coordinates = [
      for (final b in state.bands) (x % b.patchMetres, z % b.patchMetres),
    ];
    final out = Float64List(12), correction = Float64List(12);
    void add(int i, double value) {
      final next = value - correction[i], sum = out[i] + next;
      correction[i] = (sum - out[i]) - next;
      out[i] = sum;
    }

    for (var i = 0; i < modes.length; i += 12) {
      final (u, v) = coordinates[modes[i + 10].toInt()];
      final kx = modes[i + 4],
          kz = modes[i + 5],
          ax = modes[i + 6],
          az = modes[i + 7];
      var phase = (kx * u + kz * v) % (2 * math.pi);
      if (phase > math.pi) phase -= 2 * math.pi;
      final c = math.cos(phase),
          s = math.sin(phase),
          r = modes[i] * c - modes[i + 1] * s,
          im = modes[i] * s + modes[i + 1] * c,
          vr = modes[i + 2] * c - modes[i + 3] * s,
          vi = modes[i + 2] * s + modes[i + 3] * c;
      add(0, r);
      add(1, ax * im);
      add(2, az * im);
      add(3, -kx * im);
      add(4, -kz * im);
      add(5, ax * vi);
      add(6, vr);
      add(7, az * vi);
      add(8, ax * kx * r);
      add(9, ax * kz * r);
      add(10, az * kx * r);
      add(11, az * kz * r);
    }
    out[0] += state.meanLevel;
    return oceanSampleFromValues(out);
  }
}

OceanReferenceSample oceanSampleFromValues(List<double> values) {
  if (values.length != 12 || values.any((v) => !v.isFinite)) {
    throw StateError('Invalid canonical wave output.');
  }
  return OceanReferenceSample(
    height: values[0],
    displacementX: values[1],
    displacementZ: values[2],
    slopeX: values[3],
    slopeZ: values[4],
    velocityX: values[5],
    velocityY: values[6],
    velocityZ: values[7],
    displacementXX: values[8],
    displacementXZ: values[9],
    displacementZX: values[10],
    displacementZZ: values[11],
  );
}
