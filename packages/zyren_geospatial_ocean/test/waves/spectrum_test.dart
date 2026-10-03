import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

class InvalidSpectrum implements OceanSpectrumModel {
  @override
  String get id => 'invalid';
  @override
  int get version => 1;
  @override
  double energy(
    double kx,
    double kz,
    OceanWaveBand band, {
    double gravity = 9.81,
  }) => -1;
}

void main() {
  test(
    'seeded canonical coefficients are immutable, repeatable and versioned',
    () {
      final state = fixtureSea();
      final first = seedSpectrum(state, 0),
          second = seedSpectrum(fixtureSea(), 0);
      expect(first, second);
      expect(first, isNot(seedSpectrum(fixtureSea(seed: 43), 0)));
      expect(() => first[2] = 1, throwsUnsupportedError);
      final encoded = ByteData(first.length * 8);
      for (var i = 0; i < first.length; i++) {
        encoded.setFloat64(i * 8, first[i], Endian.little);
      }
      final digest = sha256.convert(encoded.buffer.asUint8List()).toString();
      expect(
        digest,
        '80c7073b2f58831998d2d2b0e69cd1cddab32589e5b3e9d0faabfec4108d36fe',
      );
      final restored = OceanSeaState.fromJson(
        jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>,
      );
      expect(restored.revision, state.revision);
      expect(seedSpectrum(restored, 0), first);
      final unknown = state.toJson()
        ..['spectrum'] = {'id': 'missing', 'version': 1};
      expect(() => OceanSeaState.fromJson(unknown), throwsArgumentError);
    },
  );
  test(
    'evolution is Hermitian with zero DC, real height and finite long-time values',
    () {
      final state = fixtureSea();
      for (final time in [0.0, 1.25, 1e10]) {
        final h = evolveSpectrum(state, 0, time);
        expect(h[0], 0);
        expect(h[1], 0);
        expect(h.every((v) => v.isFinite), isTrue);
        for (var z = 0; z < 8; z++) {
          for (var x = 0; x < 8; x++) {
            final i = 2 * (z * 8 + x),
                j = 2 * (((8 - z) % 8) * 8 + (8 - x) % 8);
            expect(h[i], closeTo(h[j], 1e-12));
            expect(h[i + 1], closeTo(-h[j + 1], 1e-12));
          }
        }
        final field = inverseDft2(h, 8);
        for (var i = 1; i < field.length; i += 2) {
          expect(field[i], closeTo(0, 1e-12));
        }
      }
      expect(evolveSpectrum(fixtureSea(wind: 0), 0, 100), everyElement(0));
    },
  );
  test('small-depth dispersion retains the shallow-water limit', () {
    expect(
      oceanDispersion(1e-9, gravity: 9.81, depthMetres: 1),
      closeTo(1e-9 * math.sqrt(9.81), 1e-20),
    );
  });
  test('canonical frequency identity survives a larger grid', () {
    final small = seedSpectrum(fixtureSea(resolution: 8), 0);
    final large = seedSpectrum(fixtureSea(resolution: 16), 0);
    for (final (x, z) in [(1, 1), (2, -1), (-2, -3)]) {
      final a = 2 * ((z % 8) * 8 + x % 8), b = 2 * ((z % 16) * 16 + x % 16);
      expect(small[a] / 64, closeTo(large[b] / 256, 1e-14));
      expect(small[a + 1] / 64, closeTo(large[b + 1] / 256, 1e-14));
    }
  });
  test('finite-depth dispersion follows deep and shallow limits', () {
    expect(oceanDispersion(0, gravity: 9.81), 0);
    expect(oceanDispersion(2, gravity: 9.81), closeTo(math.sqrt(19.62), 1e-12));
    expect(
      oceanDispersion(.001, gravity: 9.81, depthMetres: 1),
      closeTo(.001 * math.sqrt(9.81), 1e-9),
    );
    expect(
      oceanDispersion(2, gravity: 9.81, depthMetres: .1),
      lessThan(oceanDispersion(2, gravity: 9.81)),
    );
    expect(
      evolveSpectrum(fixtureSea(depth: 2), 0, 1),
      isNot(evolveSpectrum(fixtureSea(), 0, 1)),
    );
  });
  test('overlapping band weights partition energy at each wave number', () {
    final band = fixtureSea().bands.single;
    final state = OceanSeaState(
      seed: 0,
      canonicalResolution: 8,
      bands: [band, band, band],
    );
    for (var i = 0; i <= 100; i++) {
      final k = i / 100;
      expect(
        [
          for (var j = 0; j < 3; j++) state.energyWeight(j, k),
        ].reduce((a, b) => a + b),
        lessThanOrEqualTo(1.00000000001),
      );
    }
    expect(state.energyWeight(0, .25), closeTo(1 / 3, 1e-12));
  });
  test(
    'spatial derivatives and time velocity match independent finite differences',
    () {
      final spectrum = OceanSpectrum(fixtureSea());
      const e = .00001, x = 5.2, z = 8.4, time = 2.3;
      final value = spectrum.reference(x, z, time);
      final dx =
          (spectrum.reference(x + e, z, time).height -
              spectrum.reference(x - e, z, time).height) /
          (2 * e);
      final dz =
          (spectrum.reference(x, z + e, time).height -
              spectrum.reference(x, z - e, time).height) /
          (2 * e);
      final dt =
          (spectrum.reference(x, z, time + e).height -
              spectrum.reference(x, z, time - e).height) /
          (2 * e);
      expect(value.slopeX, closeTo(dx, 1e-8));
      expect(value.slopeZ, closeTo(dz, 1e-8));
      expect(value.velocityY, closeTo(dt, 1e-8));
      final left = spectrum.reference(x - e, z, time),
          right = spectrum.reference(x + e, z, time);
      final below = spectrum.reference(x, z - e, time),
          above = spectrum.reference(x, z + e, time);
      final past = spectrum.reference(x, z, time - e),
          future = spectrum.reference(x, z, time + e);
      expect(
        value.displacementXX,
        closeTo((right.displacementX - left.displacementX) / (2 * e), 1e-8),
      );
      expect(
        value.displacementXZ,
        closeTo((above.displacementX - below.displacementX) / (2 * e), 1e-8),
      );
      expect(
        value.displacementZX,
        closeTo((right.displacementZ - left.displacementZ) / (2 * e), 1e-8),
      );
      expect(
        value.displacementZZ,
        closeTo((above.displacementZ - below.displacementZ) / (2 * e), 1e-8),
      );
      expect(
        value.velocityX,
        closeTo((future.displacementX - past.displacementX) / (2 * e), 1e-8),
      );
      expect(
        value.velocityZ,
        closeTo((future.displacementZ - past.displacementZ) / (2 * e), 1e-8),
      );
      final h = inverseDft2(spectrum.evolve(0, time), 8);
      expect(
        spectrum.reference(8, 16, time).height,
        closeTo(h[2 * (2 * 8 + 1)], 1e-12),
      );
    },
  );
  test('invalid states and custom model outputs fail explicitly', () {
    expect(
      () => OceanSeaState(
        seed: 1,
        canonicalResolution: 7,
        bands: fixtureSea().bands,
      ),
      throwsArgumentError,
    );
    expect(
      () => OceanSeaState(
        seed: 1,
        canonicalResolution: 8,
        bands: fixtureSea().bands,
        gravity: double.nan,
      ),
      throwsArgumentError,
    );
    expect(
      () => OceanSeaState(
        seed: 1,
        canonicalResolution: 8,
        bands: fixtureSea().bands,
        density: -1,
      ),
      throwsArgumentError,
    );
    expect(
      () => OceanWaveBand(
        patchMetres: 0,
        minWaveNumber: 0,
        maxWaveNumber: 1,
        windSpeed: 1,
        windHeadingRadians: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => seedSpectrum(
        OceanSeaState(
          seed: 1,
          canonicalResolution: 8,
          bands: fixtureSea().bands,
          spectrum: InvalidSpectrum(),
        ),
        0,
      ),
      throwsArgumentError,
    );
    expect(
      () => evolveSpectrum(fixtureSea(), 0, double.infinity),
      throwsArgumentError,
    );
  });
}
