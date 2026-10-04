import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial_ocean/src/rendering/water_volume.dart';

void main() {
  test('submersion hysteresis stays stable around the waterline', () {
    final state = OceanSubmersion(enterBelow: -.02, exitAbove: .02);
    expect(state.update(-.03), isTrue);
    for (final distance in [-.001, .001, -.002, .002]) {
      expect(state.update(distance), isTrue);
    }
    expect(state.update(.03), isFalse);
    expect(() => state.update(double.nan), throwsArgumentError);
    expect(() => OceanSubmersion(enterBelow: .01), throwsArgumentError);
  });
  test('convex clipping excludes air before and after a bounded volume', () {
    final volume = OceanWaterVolume.box(
      min: const Vec3(-1, -2, -3),
      max: const Vec3(1, 2, 3),
    );
    final ray = volume.clip(
      const Vec3(-4, 0, 0),
      const Vec3(1, 0, 0),
      maximumDistance: 10,
    );
    expect([ray.start, ray.end, ray.metres], [3, 5, 2]);
    expect(
      volume.clip(Vec3.zero, const Vec3(0, 0, 1), maximumDistance: 2).metres,
      2,
    );
    expect(
      volume
          .clip(const Vec3(2, 0, 0), const Vec3(0, 1, 0), maximumDistance: 10)
          .metres,
      0,
    );
    expect(
      volume
          .clip(const Vec3(2, 0, 0), const Vec3(1, 0, 0), maximumDistance: 10)
          .metres,
      0,
    );
    expect(
      volume
          .clip(const Vec3(-4, 0, 0), const Vec3(1, 0, 0), maximumDistance: 4)
          .metres,
      1,
    );
  });
  test('anchored volume clipping retains metre distances at Earth scale', () {
    final origin = const Vec3(6378137, 0, 0);
    final volume = OceanWaterVolume.box(
      min: origin - Vec3.one,
      max: origin + Vec3.one,
    );
    expect(
      volume
          .clip(
            origin - const Vec3(3, 0, 0),
            const Vec3(1, 0, 0),
            maximumDistance: 10,
          )
          .metres,
      2,
    );
    final oblique = OceanWaterVolume(
      planes: [OceanWaterPlane(const Vec3(0, 0, 2), 4)],
    );
    expect(
      oblique.clip(Vec3.zero, const Vec3(0, 0, 1), maximumDistance: 10).metres,
      2,
    );
  });
}
