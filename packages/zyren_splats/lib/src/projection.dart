import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'gaussian.dart';

/// One projected covariance, retaining its original source record index.
final class ProjectedGaussian {
  final int recordIndex;
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
    this.source,
  );
  double get determinant => xx * yy - xy * xy;
  double get extentX => 3 * math.sqrt(xx);
  double get extentY => 3 * math.sqrt(yy);

  /// Pixel offsets from the projected mean. The native shader truncates at 3 sigma.
  double alphaAt(double x, double y) {
    final q = (yy * x * x - 2 * xy * x * y + xx * y * y) / determinant;
    return q > 9 ? 0 : source.opacity * math.exp(-.5 * q);
  }
}

/// Orthographic projection only. Depth clipping uses each Gaussian's center.
/// [transform] maps source coordinates minus [sourceOrigin] into world space.
List<ProjectedGaussian> projectGaussians(
  GaussianCloudData data, {
  required OrthographicCamera camera,
  required PhysicalSize size,
  Mat4? transform,
  Vec3 sourceOrigin = Vec3.zero,
}) {
  final model = transform ?? Mat4.identity();
  final combined = camera.viewProjection(size.width / size.height) * model;
  final m = combined.storage;
  final x = Vec3(m[0], m[4], m[8]) * (size.width / 2);
  final y = Vec3(m[1], m[5], m[9]) * (size.height / 2);
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
    final center = camera.projectPoint(world, size.width / size.height);
    if (center.z < 0 || center.z > 1 || splat.opacity == 0) continue;
    final covariance = splat.covariance;
    final xx = covariance.bilinear(x, x),
        xy = covariance.bilinear(x, y),
        yy = covariance.bilinear(y, y);
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
        i,
        center,
        (world - camera.position).dot(forward),
        xx,
        xy,
        yy,
        splat,
      ),
    );
  }
  result.sort((a, b) {
    final depth = b.depth.compareTo(a.depth);
    return depth == 0 ? a.recordIndex.compareTo(b.recordIndex) : depth;
  });
  return List.unmodifiable(result);
}
