import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'gaussian.dart';

/// One projected covariance, retaining its original source record index.
final class ProjectedGaussian {
  final int recordIndex, dataIndex;
  final Vec3 center;
  final double depth, xx, xy, yy;
  final GaussianSplat source;
  const ProjectedGaussian(
    this.recordIndex,
    this.center,
    this.depth,
    this.xx,
    this.xy,
    this.yy,
    this.source, {
    this.dataIndex = 0,
  });
  double get determinant => xx * yy - xy * xy;
  double get extentX => 3 * math.sqrt(xx);
  double get extentY => 3 * math.sqrt(yy);

  /// Pixel offsets from the projected mean. The native shader truncates at 3 sigma.
  double alphaAt(double x, double y) {
    final q = (yy * x * x - 2 * xy * x * y + xx * y * y) / determinant;
    return q > 9 ? 0 : source.opacity * math.exp(-.5 * q);
  }
}

/// Perspective or orthographic covariance using the projection Jacobian.
/// Depth clipping uses each Gaussian mean; intersecting volumes use mean order.
/// [transform] maps source coordinates minus [sourceOrigin] into world space.
List<ProjectedGaussian> projectGaussians(
  GaussianCloudData data, {
  required Camera camera,
  required PhysicalSize size,
  Mat4? transform,
  Vec3 sourceOrigin = Vec3.zero,
  double minimumPixelVariance = 0,
}) {
  if (!minimumPixelVariance.isFinite || minimumPixelVariance < 0) {
    throw ArgumentError('Pixel variance must be finite and nonnegative.');
  }
  final model = transform ?? Mat4.identity();
  final combined = camera.viewProjection(size.width / size.height) * model;
  final m = combined.storage;
  final v = camera.viewProjection(size.width / size.height).storage;
  final forward = (camera.target - camera.position).normalized();
  final result = <ProjectedGaussian>[];
  final t = model.storage;
  for (var i = 0; i < data.splats.length; i++) {
    final splat = data.splats[i], p = splat.mean - sourceOrigin;
    final world = Vec3(
      t[0] * p.x + t[4] * p.y + t[8] * p.z + t[12],
      t[1] * p.x + t[5] * p.y + t[9] * p.z + t[13],
      t[2] * p.x + t[6] * p.y + t[10] * p.z + t[14],
    );
    final r = world - camera.position;
    final clipX = v[0] * r.x + v[4] * r.y + v[8] * r.z + v[12];
    final clipY = v[1] * r.x + v[5] * r.y + v[9] * r.z + v[13];
    final clipZ = v[2] * r.x + v[6] * r.y + v[10] * r.z + v[14];
    final w = v[3] * r.x + v[7] * r.y + v[11] * r.z + v[15];
    if (w <= 1e-10 || !w.isFinite) continue;
    final center = Vec3(clipX / w, clipY / w, clipZ / w);
    if (!center.isFinite) continue;
    final rowW = Vec3(m[3], m[7], m[11]);
    final x =
        (Vec3(m[0], m[4], m[8]) - rowW * (clipX / w)) * (size.width / (2 * w));
    final y =
        (Vec3(m[1], m[5], m[9]) - rowW * (clipY / w)) * (size.height / (2 * w));
    if (center.z < 0 || center.z > 1 || splat.opacity == 0) continue;
    final covariance = splat.covariance;
    final xx = covariance.bilinear(x, x) + minimumPixelVariance,
        xy = covariance.bilinear(x, y),
        yy = covariance.bilinear(y, y) + minimumPixelVariance;
    final determinant = xx * yy - xy * xy;
    if ([xx, xy, yy, determinant].any((v) => !v.isFinite) ||
        xx <= 0 ||
        yy <= 0 ||
        determinant <= math.max(1e-12, xx * yy * 1e-6)) {
      throw ArgumentError(
        'Projected covariance is too small or ill-conditioned for float32 rendering.',
      );
    }
    result.add(
      ProjectedGaussian(
        data.identityAt(i).$3,
        center,
        (world - camera.position).dot(forward),
        xx,
        xy,
        yy,
        splat,
        dataIndex: i,
      ),
    );
  }
  result.sort((a, b) {
    final depth = b.depth.compareTo(a.depth);
    return depth == 0 ? a.dataIndex.compareTo(b.dataIndex) : depth;
  });
  return List.unmodifiable(result);
}
