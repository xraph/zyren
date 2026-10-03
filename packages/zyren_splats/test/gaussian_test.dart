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
  test(
    'perspective Jacobian matches finite differences under an affine transform',
    () {
      final camera = PerspectiveCamera(
        position: const Vec3(2, 1, 6),
        target: Vec3.zero,
      );
      final transform = Mat4.compose(
        const Vec3(.4, -.2, .1),
        Quat.axisAngle(const Vec3(0, 1, 0), .3),
        const Vec3(2, 1, .7),
      );
      final mean = const Vec3(.5, .3, -1);
      final covariance = GaussianCovariance(
        xx: .04,
        yy: .03,
        zz: .02,
        xy: .005,
        xz: .002,
        yz: .001,
      );
      final cloud = data([splat(mean, covariance: covariance)]);
      final p = projectGaussians(
        cloud,
        camera: camera,
        size: PhysicalSize(320, 240),
        transform: transform,
      ).single;
      Vec3 world(Vec3 v) {
        final m = transform.storage;
        return Vec3(
          m[0] * v.x + m[4] * v.y + m[8] * v.z + m[12],
          m[1] * v.x + m[5] * v.y + m[9] * v.z + m[13],
          m[2] * v.x + m[6] * v.y + m[10] * v.z + m[14],
        );
      }

      final dx = <double>[], dy = <double>[];
      for (final axis in [
        const Vec3(1, 0, 0),
        const Vec3(0, 1, 0),
        const Vec3(0, 0, 1),
      ]) {
        final a = camera.projectPoint(world(mean + axis * 1e-5), 320 / 240);
        final b = camera.projectPoint(world(mean - axis * 1e-5), 320 / 240);
        dx.add((a.x - b.x) / (2e-5) * 160);
        dy.add((a.y - b.y) / (2e-5) * 120);
      }
      final x = Vec3(dx[0], dx[1], dx[2]), y = Vec3(dy[0], dy[1], dy[2]);
      expect(p.xx, closeTo(covariance.bilinear(x, x), 1e-6));
      expect(p.xy, closeTo(covariance.bilinear(x, y), 1e-6));
      expect(p.yy, closeTo(covariance.bilinear(y, y), 1e-6));
    },
  );
  test(
    'perspective clips behind-camera and near means, retains subset identity',
    () {
      final source = data([
        splat(const Vec3(0, 0, 7)),
        splat(const Vec3(0, 0, 4.95)),
        splat(Vec3.zero),
      ]);
      final subset = source.select([2, 0, 1]);
      final p = projectGaussians(
        subset,
        camera: PerspectiveCamera(near: .1),
        size: PhysicalSize(100, 100),
      );
      expect(p.length, 1);
      expect(p.single.recordIndex, 2);
      expect(p.single.dataIndex, 0);
      expect(subset.identityAt(p.single.dataIndex).$3, 2);
    },
  );
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
