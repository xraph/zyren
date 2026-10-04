import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

void main() {
  test('Beer-Lambert attenuation composes over segments', () {
    const extinction = Vec3(1, 2, 3);
    expect(waterTransmittance(extinction, 0), const Vec3(1, 1, 1));
    final a = waterTransmittance(extinction, .75);
    final b = waterTransmittance(extinction, 1.25);
    final whole = waterTransmittance(extinction, 2);
    expect(a.x * b.x, closeTo(whole.x, 1e-15));
    expect(a.y * b.y, closeTo(whole.y, 1e-15));
    expect(a.z * b.z, closeTo(whole.z, 1e-15));
    expect(whole.x, closeTo(math.exp(-2), 1e-15));
    expect(waterTransmittance(const Vec3(0, 0, 0), 1e6), const Vec3(1, 1, 1));
    expect(() => waterTransmittance(extinction, -1), throwsArgumentError);
    expect(
      () => waterTransmittance(const Vec3(-1, 0, 0), 1),
      throwsArgumentError,
    );
    expect(
      () => waterTransmittance(extinction, double.nan),
      throwsArgumentError,
    );
  });
  test('exact dielectric Fresnel has reciprocity, Brewster and TIR limits', () {
    expect(waterFresnel(1, 1, 1.333), closeTo(.02037, .0001));
    expect(waterFresnel(.1, 1.333, 1), 1);
    expect(waterFresnel(0, 1, 1.333), 1);
    expect(waterFresnel(0, 1.333, 1.333), 0);
    for (var i = 1; i <= 100; i++) {
      final ci = i / 100, ct = math.sqrt(1 - (1 - ci * ci) / (1.333 * 1.333));
      expect(
        waterFresnel(ci, 1, 1.333),
        closeTo(waterFresnel(ct, 1.333, 1), 2e-13),
      );
      expect(waterFresnel(ci, 1, 1.333), inInclusiveRange(0, 1));
    }
    final brewster = math.atan(1.333);
    final rs = math.pow((1 - 1.333 * 1.333) / (1 + 1.333 * 1.333), 2) / 2;
    expect(waterFresnel(math.cos(brewster), 1, 1.333), closeTo(rs, 1e-14));
    expect(() => waterFresnel(-.1, 1, 1.333), throwsArgumentError);
    expect(() => waterFresnel(1, 0, 1.333), throwsArgumentError);
  });
  test(
    'homogeneous source integration conserves bounded incident radiance',
    () {
      final water = OceanOptics(
        absorptionPerMetre: const Vec3(.5, 0, 0),
        scatteringPerMetre: const Vec3(.5, .4, 0),
      );
      final c = water.integrate(const Vec3(1, 1, 1), const Vec3(1, 1, 1), 10);
      expect(c.x, closeTo(.5 + .5 * math.exp(-10), 1e-14));
      expect(c.y, closeTo(1, 1e-14));
      expect(c.z, 1);
      expect(() => OceanOptics(roughness: 1.1), throwsArgumentError);
      expect(
        () => OceanOptics(scatteringPerMetre: const Vec3(0, -1, 0)),
        throwsArgumentError,
      );
    },
  );
}
