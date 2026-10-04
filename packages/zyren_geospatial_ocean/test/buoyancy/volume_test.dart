import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

void main() {
  test('sphere caps have exact dry, half and full volumes and centroids', () {
    expect(submergedSphereVolume(1, 0), 0);
    expect(submergedSphereVolume(1, 1), closeTo(2 * math.pi / 3, 1e-12));
    expect(submergedSphereVolume(1, 2), closeTo(4 * math.pi / 3, 1e-12));
    expect(submergedSphereVolume(1, -1), 0);
    expect(submergedSphereVolume(1, 3), submergedSphereVolume(1, 2));
    expect(submergedSphereCentroidOffset(1, 1), closeTo(-3 / 8, 1e-12));
    expect(submergedSphereCentroidOffset(1, 2), 0);
    for (final r in [0.0, -1.0, double.nan, double.infinity]) {
      expect(() => submergedSphereVolume(r, 1), throwsArgumentError);
    }
    expect(() => submergedSphereVolume(1, double.nan), throwsArgumentError);
  });
  test('overlapping probes need explicit volume weights', () {
    final p = [
      BuoyancyProbe(Vec3.zero, 1),
      BuoyancyProbe(const Vec3(1, 0, 0), 1),
    ];
    expect(() => BuoyancyProbes(p), throwsArgumentError);
    final shape = BuoyancyProbes(
      p,
      partition: BuoyancyProbePartition(
        weights: [.5, .5],
        declaredVolume: 4 * math.pi / 3,
      ),
    );
    expect(shape.volume, closeTo(4 * math.pi / 3, 1e-12));
    expect(
      () => BuoyancyProbes(
        p,
        partition: BuoyancyProbePartition(weights: [.5, .5], declaredVolume: 1),
      ),
      throwsArgumentError,
    );
  });
  test('tetrahedron clipping agrees with independent similar tetrahedra', () {
    final cell = BuoyancyTetrahedron(
      Vec3.zero,
      const Vec3(1, 0, 0),
      const Vec3(0, 1, 0),
      const Vec3(0, 0, 1),
    );
    final normal = const Vec3(1, 1, 1).normalized();
    for (final t in [.01, .1, .25, .5, .9, 1.0]) {
      final wet = cell.clip(normal * (t / math.sqrt(3)), normal);
      expect(wet.volume, closeTo(t * t * t / 6, 2e-15));
      expect(
        wet.centroid!.distanceTo(Vec3(t / 4, t / 4, t / 4)),
        lessThan(1e-14),
      );
      final complement = cell.clip(normal * (t / math.sqrt(3)), -normal);
      expect(wet.volume + complement.volume, closeTo(1 / 6, 2e-15));
      final moment =
          wet.centroid! * wet.volume +
          complement.centroidOrZero * complement.volume;
      expect(moment.distanceTo(const Vec3(1, 1, 1) / 24), lessThan(1e-14));
    }
    expect(cell.clip(const Vec3(-1, 0, 0), const Vec3(1, 0, 0)).volume, 0);
  });
}
