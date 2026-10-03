import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'packed native fields match canonical displacement, derivatives and velocity',
    () async {
      final backend = await NativeBackend.create();
      addTearDown(backend.close);
      final scope = GpuScope.fromBackend(backend);
      addTearDown(scope.close);
      final state = fixtureSea(depth: 20), reference = OceanSpectrum(state);
      final field = await OceanWaveFieldGpu.create(scope, state);
      addTearDown(field.close);
      for (final time in [0.0, 2.3, 32.0, 63.9, 1e10 + .25]) {
        final snapshot = await field.evaluate(time, resolution: 8);
        final data = await field.debugRead(snapshot);
        expect(snapshot.dispatches, 8);
        expect(snapshot.bands.single.unresolvedSlopeVariance, 0);
        expect(
          snapshot.logicalPayloadBytes,
          (await backend.resourceStats()).residentBytes,
        );
        for (var z = 0; z < 8; z++) {
          for (var x = 0; x < 8; x++) {
            final v = reference.reference(x * 8.0, z * 8.0, time),
                i = 4 * (z * 8 + x);
            final expected = [
              v.displacementX,
              v.height,
              v.displacementZ,
              v.horizontalJacobian,
              v.slopeX,
              v.slopeZ,
              v.displacementXX,
              v.displacementZZ,
              v.velocityX,
              v.velocityY,
              v.velocityZ,
              v.displacementXZ,
            ];
            final actual = [
              ...data.displacement.sublist(i, i + 4),
              ...data.derivatives.sublist(i, i + 4),
              ...data.velocity.sublist(i, i + 4),
            ];
            for (var c = 0; c < 12; c++) {
              expect(
                actual[c],
                closeTo(expected[c], 3e-5),
                reason: 't=$time x=$x z=$z channel=$c',
              );
            }
          }
        }
      }
      final physical = reference.reference(4, 8, 2.3);
      final small = await field.evaluate(2.3, resolution: 4);
      expect(small.bands.single.unresolvedSlopeVariance, greaterThan(0));
      expect(reference.reference(4, 8, 2.3).height, physical.height);
      expect(small.seaStateRevision, state.revision);
      final full = await field.evaluate(2.3, resolution: 8);
      expect(full.bands.single.unresolvedSlopeVariance, 0);
      expect(small.isCurrent, isFalse);
      await expectLater(field.debugRead(small), throwsStateError);
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'zero wind remains flat and overlapping native bands sum to the same reference',
    () async {
      final backend = await NativeBackend.create();
      addTearDown(backend.close);
      final scope = GpuScope.fromBackend(backend);
      addTearDown(scope.close);
      final calm = await OceanWaveFieldGpu.create(scope, fixtureSea(wind: 0));
      final snapshot = await calm.evaluate(1000, resolution: 8);
      final flat = await calm.debugRead(snapshot);
      for (var i = 0; i < flat.displacement.length; i++) {
        expect(flat.displacement[i], i % 4 == 3 ? 1 : 0);
      }
      expect(flat.velocity, everyElement(0));
      await calm.close();
      final band = fixtureSea().bands.single;
      final state = OceanSeaState(
        seed: 42,
        canonicalResolution: 8,
        bands: [band, band],
      );
      final field = await OceanWaveFieldGpu.create(scope, state);
      final combined = await field.evaluate(2.3, resolution: 8);
      final a = await field.debugRead(combined),
          b = await field.debugRead(combined, band: 1);
      final expected = OceanSpectrum(state).reference(8, 16, 2.3);
      const i = 4 * (2 * 8 + 1);
      expect(
        a.displacement[i + 1] + b.displacement[i + 1],
        closeTo(expected.height, 3e-5),
      );
      expect(
        a.velocity[i + 1] + b.velocity[i + 1],
        closeTo(expected.velocityY, 3e-5),
      );
      await field.close();
      expect((await backend.resourceStats()).liveAllocations, 0);
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
