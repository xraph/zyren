import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_splats/zyren_splats.dart';

GaussianSplat splat(Vec3 mean, {GaussianCovariance? covariance}) =>
    GaussianSplat(
      mean: mean,
      covariance: covariance ?? GaussianCovariance(xx: .04, yy: .01, zz: .01),
      color: const Color3(1, 0, 0),
      opacity: .8,
    );
GaussianCloudData data(
  Iterable<GaussianSplat> splats, {
  SplatLimits limits = const SplatLimits(),
}) => GaussianCloudData(
  sourceUri: Uri.parse('memory:gaussians'),
  sourceVersion: '1',
  splats: splats,
  limits: limits,
);

void main() {
  test('rejects nonpositive and indefinite covariances', () {
    for (final create in [
      () => GaussianCovariance(xx: 0, yy: 1, zz: 1),
      () => GaussianCovariance(xx: 1, yy: 1, zz: 1, xy: 2),
      () => GaussianCovariance(xx: 1, yy: 1, zz: -1),
      () => GaussianCovariance(xx: double.nan, yy: 1, zz: 1),
    ]) {
      expect(create, throwsArgumentError);
    }
  });
  test(
    'orthographic covariance and Gaussian falloff agree with analytic values',
    () {
      final projected = projectGaussians(
        data([splat(Vec3.zero)]),
        camera: OrthographicCamera(),
        size: PhysicalSize(100, 100),
      ).single;
      expect(projected.xx, closeTo(100, 1e-10));
      expect(projected.yy, closeTo(25, 1e-10));
      expect(projected.alphaAt(0, 0), .8);
      expect(projected.alphaAt(10, 0), closeTo(.8 * math.exp(-.5), 1e-12));
      expect(projected.alphaAt(0, 5), closeTo(.8 * math.exp(-.5), 1e-12));
      expect(projected.alphaAt(31, 0), 0);
    },
  );
  test('transformed covariance rotates and scales with its scene object', () {
    final projected = projectGaussians(
      data([splat(Vec3.zero)]),
      camera: OrthographicCamera(),
      size: PhysicalSize(100, 100),
      transform: Mat4.compose(
        Vec3.zero,
        Quat.axisAngle(const Vec3(0, 0, 1), math.pi / 2),
        const Vec3(2, 1, 1),
      ),
    ).single;
    expect(projected.xx, closeTo(25, 1e-10));
    expect(projected.yy, closeTo(400, 1e-10));
  });
  test('depth order preserves original record identities and stable ties', () {
    final cloud = data([
      splat(const Vec3(0, 0, 1)),
      splat(const Vec3(0, 0, -1)),
      splat(const Vec3(0, 0, -1)),
    ]);
    final projected = projectGaussians(
      cloud,
      camera: OrthographicCamera(),
      size: PhysicalSize(64, 64),
    );
    expect(projected.map((p) => p.recordIndex), [1, 2, 0]);
    expect(cloud.identityAt(projected.first.recordIndex), (
      Uri.parse('memory:gaussians'),
      '1',
      1,
    ));
  });
  test('bounded iterable consumption stops before unbounded ingestion', () {
    var consumed = 0;
    Iterable<GaussianSplat> records() sync* {
      while (true) {
        consumed++;
        yield splat(Vec3.zero);
      }
    }

    expect(
      () => data(records(), limits: const SplatLimits(maxSplats: 2)),
      throwsStateError,
    );
    expect(consumed, 3);
  });
}
