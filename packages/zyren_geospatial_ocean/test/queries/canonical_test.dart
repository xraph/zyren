import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'cached canonical modes match the independent reference at arbitrary coordinates',
    () {
      final state = fixtureSea(),
          reference = OceanSpectrum(state),
          field = OceanCanonicalField(state, maxModes: 8192);
      for (final time in [0.0, 2.5, 1e10 + .25]) {
        final snapshot = field.at(time);
        expect(snapshot.seaStateRevision, state.revision);
        for (final (x, z) in [
          (0.0, 0.0),
          (5.3, -9.7),
          (6378137.13, -4412323.55),
        ]) {
          final actual = snapshot.sample(x, z),
              expected = reference.reference(x, z, time);
          final a = [
            actual.height,
            actual.displacementX,
            actual.displacementZ,
            actual.slopeX,
            actual.slopeZ,
            actual.velocityX,
            actual.velocityY,
            actual.velocityZ,
            actual.displacementXX,
            actual.displacementXZ,
            actual.displacementZX,
            actual.displacementZZ,
          ];
          final b = [
            expected.height,
            expected.displacementX,
            expected.displacementZ,
            expected.slopeX,
            expected.slopeZ,
            expected.velocityX,
            expected.velocityY,
            expected.velocityZ,
            expected.displacementXX,
            expected.displacementXZ,
            expected.displacementZX,
            expected.displacementZZ,
          ];
          for (var i = 0; i < a.length; i++) {
            expect(a[i], closeTo(b[i], 1e-11));
          }
          final envelope = snapshot.envelope;
          final left = snapshot.sample(x - .001, z),
              right = snapshot.sample(x + .001, z);
          final velocityGradient =
              math.sqrt(
                math.pow(right.velocityX - left.velocityX, 2) +
                    math.pow(right.velocityY - left.velocityY, 2) +
                    math.pow(right.velocityZ - left.velocityZ, 2),
              ) /
              .002;
          expect(
            velocityGradient,
            lessThanOrEqualTo(envelope.velocityGradient),
          );
          expect(
            (actual.height - state.meanLevel).abs(),
            lessThanOrEqualTo(envelope.height),
          );
          expect(
            math.sqrt(
              actual.slopeX * actual.slopeX + actual.slopeZ * actual.slopeZ,
            ),
            lessThanOrEqualTo(envelope.slope),
          );
          expect(
            math.sqrt(
              actual.displacementX * actual.displacementX +
                  actual.displacementZ * actual.displacementZ,
            ),
            lessThanOrEqualTo(envelope.displacement),
          );
        }
      }
    },
  );
  test(
    'mode admission counts canonical work before seeding and snapshots are immutable',
    () {
      expect(
        () => OceanCanonicalField(fixtureSea(resolution: 64), maxModes: 16),
        throwsArgumentError,
      );
      final field = OceanCanonicalField(fixtureSea(wind: 0), maxModes: 64),
          snapshot = field.at(0);
      expect(snapshot.modeCount, 0);
      expect(snapshot.sample(1, 2).height, 0);
      expect(snapshot.envelope.height, 0);
      expect(() => snapshot.modes[0] = 1, throwsUnsupportedError);
      expect(() => field.at(double.nan), throwsArgumentError);
    },
  );
  test(
    'logical-memory admission happens before allocation and mode buffers cannot be mutated',
    () {
      expect(
        () => OceanCanonicalField(
          fixtureSea(resolution: 256),
          maxModes: 65536,
          maxLogicalBytes: 1024,
        ),
        throwsArgumentError,
      );
      final field = OceanCanonicalField(fixtureSea(), maxModes: 64);
      expect(field.logicalWorkBytes, 64 * (120 + 32));
      final snapshot = field.at(1);
      expect(snapshot.modeCount, greaterThan(0));
      expect(() => snapshot.modes[0] = 0, throwsUnsupportedError);
      expect(
        () => snapshot.modes.buffer.asFloat64List()[0] = 0,
        throwsUnsupportedError,
      );
    },
  );
}
