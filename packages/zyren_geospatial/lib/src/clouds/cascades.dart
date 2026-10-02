import 'dart:math' as math;
import 'package:zyren/zyren.dart';

enum CloudShadowSplit { uniform, logarithmic, practical }

/// One source-compatible orthographic cascade. Matrices use OpenGL clip Z and
/// bottom-left UVs; atlas sampling converts Y to the native top-left convention.
final class CloudShadowCascade {
  final (double, double) interval;
  final Mat4 matrix,
      inverseMatrix,
      projectionMatrix,
      viewMatrix,
      inverseViewMatrix;
  final double radius;
  CloudShadowCascade._(
    this.interval,
    this.projectionMatrix,
    this.inverseViewMatrix,
    this.radius,
  ) : viewMatrix = inverseViewMatrix.inverted(),
      matrix = projectionMatrix * inverseViewMatrix.inverted(),
      inverseMatrix = inverseViewMatrix * projectionMatrix.inverted();
}

/// Source frustum splits and texel-snapped shadow projection in double precision.
/// A zero-near orthographic camera uses uniform splits, since logarithms need a
/// positive near distance. World translations do not enter GPU camera matrices.
final class CloudShadowCascades {
  final List<CloudShadowCascade> cascades;
  final double near, far;
  CloudShadowCascades._(
    Iterable<CloudShadowCascade> values,
    this.near,
    this.far,
  ) : cascades = List.unmodifiable(values);
  factory CloudShadowCascades.build({
    required Camera camera,
    required double aspect,
    required Vec3 sunDirection,
    int count = 3,
    int mapWidth = 256,
    int mapHeight = 256,
    double maxFar = 200000,
    double farScale = 1,
    double splitLambda = .5,
    double margin = 0,
    double distance = 1,
    bool fade = true,
    CloudShadowSplit splitMode = CloudShadowSplit.practical,
  }) {
    RangeError.checkValueInInterval(count, 1, 4, 'count');
    RangeError.checkValueInInterval(mapWidth, 1, 1024, 'mapWidth');
    RangeError.checkValueInInterval(mapHeight, 1, 1024, 'mapHeight');
    if (!aspect.isFinite ||
        aspect <= 0 ||
        !maxFar.isFinite ||
        maxFar <= 0 ||
        maxFar > 1e9 ||
        !farScale.isFinite ||
        farScale <= 0 ||
        farScale > 1 ||
        !splitLambda.isFinite ||
        splitLambda < 0 ||
        splitLambda > 1 ||
        !margin.isFinite ||
        margin < 0 ||
        margin > 1e7 ||
        !distance.isFinite ||
        distance <= 0 ||
        distance > 1e8 ||
        !sunDirection.length.isFinite ||
        sunDirection.length < 1e-12) {
      throw ArgumentError('Invalid cloud shadow cascade settings.');
    }
    camera.viewProjection(aspect);
    final double near, far;
    if (camera is PerspectiveCamera) {
      near = camera.near;
      far = math.min(maxFar, camera.far * farScale);
    } else if (camera is OrthographicCamera) {
      near = camera.near;
      far = math.min(maxFar, camera.far * farScale);
    } else {
      throw ArgumentError(
        'Cloud shadows require a perspective or orthographic camera.',
      );
    }
    if (far <= near) {
      throw ArgumentError('Cloud shadow far distance must exceed camera near.');
    }
    final forward = (camera.target - camera.position).normalized();
    final right = forward.cross(camera.up).normalized(),
        up = right.cross(forward);
    final nearCorners = <Vec3>[], farCorners = <Vec3>[];
    for (final corner in [(1.0, 1.0), (1.0, -1.0), (-1.0, -1.0), (-1.0, 1.0)]) {
      if (camera is PerspectiveCamera) {
        final h = math.tan(camera.fieldOfView / 2) / camera.zoom;
        final ray = Vec3(corner.$1 * h * aspect, corner.$2 * h, -1);
        nearCorners.add(ray * near);
        farCorners.add(ray * far);
      } else if (camera is OrthographicCamera) {
        final x =
            (camera.left + camera.right) / 2 +
            corner.$1 * (camera.right - camera.left) / (2 * camera.zoom);
        final y =
            (camera.bottom + camera.top) / 2 +
            corner.$2 * (camera.top - camera.bottom) / (2 * camera.zoom);
        nearCorners.add(Vec3(x, y, -near));
        farCorners.add(Vec3(x, y, -far));
      }
    }
    final splits = <double>[];
    for (var i = 1; i <= count; i++) {
      final uniform = (near + (far - near) * i / count) / far;
      final logarithmic = near == 0
          ? uniform
          : near * math.pow(far / near, i / count) / far;
      splits.add(switch (splitMode) {
        CloudShadowSplit.uniform => uniform,
        CloudShadowSplit.logarithmic => logarithmic,
        CloudShadowSplit.practical =>
          uniform + (logarithmic - uniform) * splitLambda,
      });
    }
    final sun = sunDirection.normalized();
    final light = _orientation(sun), inverseLight = _orientation(-sun);
    Vec3 lightPoint(Vec3 p) {
      final world = camera.position + right * p.x + up * p.y - forward * p.z;
      return Vec3(
        world.dot(light.$1),
        world.dot(light.$2),
        world.dot(light.$3),
      );
    }

    final result = <CloudShadowCascade>[];
    for (var i = 0; i < count; i++) {
      Vec3 corner(int c, double t) =>
          nearCorners[c] + (farCorners[c] - nearCorners[c]) * t;
      final n = [
        for (var c = 0; c < 4; c++)
          i == 0 ? nearCorners[c] : corner(c, splits[i - 1]),
      ];
      final f = [
        for (var c = 0; c < 4; c++)
          i == count - 1 ? farCorners[c] : corner(c, splits[i]),
      ];
      var diagonal = math.max(f[0].distanceTo(f[2]), f[0].distanceTo(n[2]));
      if (fade) {
        final depth = f[0].z / (far - near);
        diagonal += .25 * depth * depth * (far - near);
      }
      final radius = diagonal * .5;
      final points = [...n, ...f].map(lightPoint).toList();
      final lo = Vec3(
        points.map((p) => p.x).reduce(math.min),
        points.map((p) => p.y).reduce(math.min),
        points.map((p) => p.z).reduce(math.min),
      );
      final hi = Vec3(
        points.map((p) => p.x).reduce(math.max),
        points.map((p) => p.y).reduce(math.max),
        points.map((p) => p.z).reduce(math.max),
      );
      final center = (lo + hi) * .5,
          texelX = radius * 2 / mapWidth,
          texelY = radius * 2 / mapHeight;
      // Math.round in the source rounds negative ties toward positive infinity.
      final x = (center.x / texelX + .5).floor() * texelX,
          y = (center.y / texelY + .5).floor() * texelY;
      final position =
          light.$1 * x +
          light.$2 * y +
          light.$3 * (hi.z + margin) +
          sun * distance;
      final view = Mat4([
        ...inverseLight.$1.storage,
        0,
        ...inverseLight.$2.storage,
        0,
        ...inverseLight.$3.storage,
        0,
        ...position.storage,
        1,
      ]);
      final projection = Mat4([
        1 / radius,
        0,
        0,
        0,
        0,
        1 / radius,
        0,
        0,
        0,
        0,
        -1 / (radius + margin),
        0,
        0,
        0,
        -radius / (radius + margin),
        1,
      ]);
      result.add(
        CloudShadowCascade._(
          (i == 0 ? 0 : splits[i - 1], splits[i]),
          projection,
          view,
          radius,
        ),
      );
    }
    return CloudShadowCascades._(result, near, far);
  }
}

(Vec3, Vec3, Vec3) _orientation(Vec3 back) {
  var z = back.normalized();
  const up = Vec3(0, 1, 0);
  var x = up.cross(z);
  if (x.length2 == 0) {
    z = (z + const Vec3(0, 0, .0001)).normalized();
    x = up.cross(z);
  }
  x = x.normalized();
  return (x, z.cross(x), z);
}
