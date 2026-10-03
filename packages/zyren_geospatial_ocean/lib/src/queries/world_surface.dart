import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../surface/cube_patch.dart';
import '../surface/wave_chart.dart';
import '../waves/spectrum.dart';

/// Nearest normal footpoint, restricted to the unambiguous near-surface interior.
({Vec3 position, Vec3 normal, double height}) oceanEllipsoidFootpoint(
  Vec3 point,
  Ellipsoid ellipsoid,
) {
  validateOceanEllipsoid(ellipsoid);
  final scale = ellipsoid.maximumRadius;
  if (!point.isFinite ||
      point.length < 1e-12 * scale ||
      point.length > 1024 * scale) {
    throw ArgumentError(
      'Ocean queries require a finite position near the declared body.',
    );
  }
  final q = point / scale,
      b = Vec3(
        math.pow(ellipsoid.x / scale, 2).toDouble(),
        math.pow(ellipsoid.y / scale, 2).toDouble(),
        math.pow(ellipsoid.z / scale, 2).toDouble(),
      );
  double equation(double lambda) =>
      b.x * q.x * q.x / math.pow(lambda + b.x, 2) +
      b.y * q.y * q.y / math.pow(lambda + b.y, 2) +
      b.z * q.z * q.z / math.pow(lambda + b.z, 2);
  final atZero = equation(0);
  var low = atZero >= 1
      ? 0.0
      : -math.min(b.x, math.min(b.y, b.z)) * (1 - 1e-12);
  var high = atZero <= 1 ? 0.0 : math.max(1.0, q.length2);
  if (equation(low) < 1 || equation(high) > 1) {
    throw ArgumentError('Ambiguous ellipsoid interior.');
  }
  for (var iteration = 0; iteration < 100; iteration++) {
    final middle = (low + high) / 2;
    if (equation(middle) > 1) {
      low = middle;
    } else {
      high = middle;
    }
  }
  final lambda = (low + high) / 2;
  final position =
      Vec3(
        b.x * q.x / (lambda + b.x),
        b.y * q.y / (lambda + b.y),
        b.z * q.z / (lambda + b.z),
      ) *
      scale;
  final normal = ellipsoid.surfaceNormal(position),
      height = (point - position).dot(normal);
  final curvatureRadius =
      ellipsoid.minimumRadius * ellipsoid.minimumRadius / scale;
  if (height < -.1 * curvatureRadius ||
      !height.isFinite ||
      (point - position - normal * height).length > 1e-8 * scale) {
    throw ArgumentError('Ambiguous or unresolved ellipsoid footpoint.');
  }
  return (position: position, normal: normal, height: height);
}

final class OceanWorldSurface {
  final Vec3 position, normal, velocity, eastDerivative, northDerivative;
  final double height, orientation;
  const OceanWorldSurface._(
    this.position,
    this.normal,
    this.velocity,
    this.eastDerivative,
    this.northDerivative,
    this.height,
    this.orientation,
  );
}

/// Blends the canonical material map and differentiates the tangent projection.
OceanWorldSurface blendOceanSurface(
  OceanChartPoint point,
  OceanReferenceSample Function(OceanChartCoordinate) sample,
) {
  var height = 0.0, he = 0.0, hn = 0.0, verticalVelocity = 0.0;
  var v = Vec3.zero, ve = Vec3.zero, vn = Vec3.zero, velocity = Vec3.zero;
  for (final c in point.coordinates) {
    final f = sample(c), axes = oceanCubeFaces[c.id];
    final local = axes.u * f.displacementX + axes.v * f.displacementZ;
    final de =
        axes.u * (f.displacementXX * c.uEast + f.displacementXZ * c.vEast) +
        axes.v * (f.displacementZX * c.uEast + f.displacementZZ * c.vEast);
    final dn =
        axes.u * (f.displacementXX * c.uNorth + f.displacementXZ * c.vNorth) +
        axes.v * (f.displacementZX * c.uNorth + f.displacementZZ * c.vNorth);
    height += c.weight * f.height;
    he +=
        c.weightEast * f.height +
        c.weight * (f.slopeX * c.uEast + f.slopeZ * c.vEast);
    hn +=
        c.weightNorth * f.height +
        c.weight * (f.slopeX * c.uNorth + f.slopeZ * c.vNorth);
    v = v + local * c.weight;
    ve = ve + local * c.weightEast + de * c.weight;
    vn = vn + local * c.weightNorth + dn * c.weight;
    velocity =
        velocity + (axes.u * f.velocityX + axes.v * f.velocityZ) * c.weight;
    verticalVelocity += c.weight * f.velocityY;
  }
  final n = point.normal,
      ne = point.normalEast,
      nn = point.normalNorth,
      dot = n.dot(v);
  final displacement = v - n * dot;
  final east =
      point.east +
      ne * height +
      n * he +
      ve -
      ne * dot -
      n * (ne.dot(v) + n.dot(ve));
  final north =
      point.north +
      nn * height +
      n * hn +
      vn -
      nn * dot -
      n * (nn.dot(v) + n.dot(vn));
  final cross = east.cross(north),
      position = point.position + n * height + displacement;
  final fluid = velocity - n * n.dot(velocity) + n * verticalVelocity;
  if (!position.isFinite ||
      !east.isFinite ||
      !north.isFinite ||
      !fluid.isFinite ||
      !cross.isFinite ||
      !height.isFinite) {
    throw StateError('World wave blend overflowed.');
  }
  return OceanWorldSurface._(
    position,
    cross.normalized(),
    fluid,
    east,
    north,
    height,
    cross.dot(n),
  );
}
