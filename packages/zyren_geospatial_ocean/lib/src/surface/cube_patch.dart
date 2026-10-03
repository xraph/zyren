import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

/// Outward right-handed cube faces: +X, -X, +Y, -Y, +Z, -Z.
const oceanCubeFaces = <({Vec3 normal, Vec3 u, Vec3 v})>[
  (normal: Vec3(1, 0, 0), u: Vec3(0, 1, 0), v: Vec3(0, 0, 1)),
  (normal: Vec3(-1, 0, 0), u: Vec3(0, -1, 0), v: Vec3(0, 0, 1)),
  (normal: Vec3(0, 1, 0), u: Vec3(-1, 0, 0), v: Vec3(0, 0, 1)),
  (normal: Vec3(0, -1, 0), u: Vec3(1, 0, 0), v: Vec3(0, 0, 1)),
  (normal: Vec3(0, 0, 1), u: Vec3(1, 0, 0), v: Vec3(0, 1, 0)),
  (normal: Vec3(0, 0, -1), u: Vec3(1, 0, 0), v: Vec3(0, -1, 0)),
];

enum OceanPatchSide { south, east, north, west }

final class OceanPatchId {
  final int face, level, x, y;
  OceanPatchId({
    required this.face,
    required this.level,
    required this.x,
    required this.y,
  }) {
    if (face < 0 ||
        face >= 6 ||
        level < 0 ||
        level > 20 ||
        x < 0 ||
        y < 0 ||
        x >= 1 << level ||
        y >= 1 << level) {
      throw ArgumentError('Invalid cube patch identity.');
    }
  }
  OceanPatchId? get parent => level == 0
      ? null
      : OceanPatchId(face: face, level: level - 1, x: x ~/ 2, y: y ~/ 2);
  List<OceanPatchId> get children {
    if (level == 20) throw StateError('Maximum ocean patch level reached.');
    return [
      for (var dy = 0; dy < 2; dy++)
        for (var dx = 0; dx < 2; dx++)
          OceanPatchId(
            face: face,
            level: level + 1,
            x: 2 * x + dx,
            y: 2 * y + dy,
          ),
    ];
  }

  Vec3 cubePoint(double u, double v) {
    if (!u.isFinite || !v.isFinite) {
      throw ArgumentError('Finite cube coordinates required.');
    }
    final axes = oceanCubeFaces[face], count = 1 << level;
    return axes.normal +
        axes.u * (2 * (x + u) / count - 1) +
        axes.v * (2 * (y + v) / count - 1);
  }

  Vec3 point(double u, double v, [Ellipsoid ellipsoid = Ellipsoid.wgs84]) {
    if (u < 0 || u > 1 || v < 0 || v > 1) {
      throw ArgumentError('Patch point lies outside its coverage.');
    }
    validateOceanEllipsoid(ellipsoid);
    final p = cubePoint(u, v);
    return p /
        math.sqrt(
          p.x * p.x / (ellipsoid.x * ellipsoid.x) +
              p.y * p.y / (ellipsoid.y * ellipsoid.y) +
              p.z * p.z / (ellipsoid.z * ellipsoid.z),
        );
  }

  ({Vec3 center, double radius}) bounds(
    Ellipsoid ellipsoid, {
    double displacementBoundMetres = 0,
  }) {
    if (!displacementBoundMetres.isFinite ||
        displacementBoundMetres < 0 ||
        displacementBoundMetres >= ellipsoid.minimumRadius * .1) {
      throw ArgumentError(
        'Displacement bound must be finite and smaller than a tenth of the body radius.',
      );
    }
    final center = point(.5, .5, ellipsoid),
        direction = cubePoint(.5, .5).normalized();
    var chord = 0.0;
    for (final (u, v) in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]) {
      chord = math.max(
        chord,
        direction.distanceTo(cubePoint(u, v).normalized()),
      );
    }
    final big = ellipsoid.maximumRadius, small = ellipsoid.minimumRadius;
    final radialLipschitz = .5 * big * (big * big / (small * small) - 1);
    return (
      center: center,
      radius: (big + radialLipschitz) * chord + displacementBoundMetres,
    );
  }

  ({double u, double v}) localCoordinates(Vec3 cube) {
    final axes = oceanCubeFaces[face],
        denominator = cube.dot(axes.normal),
        count = 1 << level;
    if (denominator <= 0) {
      throw ArgumentError('Point does not belong to this cube hemisphere.');
    }
    return (
      u: (cube.dot(axes.u) / denominator + 1) * count / 2 - x,
      v: (cube.dot(axes.v) / denominator + 1) * count / 2 - y,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OceanPatchId &&
      face == other.face &&
      level == other.level &&
      x == other.x &&
      y == other.y;
  @override
  int get hashCode => Object.hash(face, level, x, y);
  @override
  String toString() => '$face/$level/$x/$y';
}

int oceanCubeFace(Vec3 point) {
  if (!point.isFinite || point.length2 == 0) {
    throw ArgumentError('A cube direction must be finite and nonzero.');
  }
  final x = point.x.abs(), y = point.y.abs(), z = point.z.abs();
  if (x >= y && x >= z) return point.x >= 0 ? 0 : 1;
  if (y >= z) return point.y >= 0 ? 2 : 3;
  return point.z >= 0 ? 4 : 5;
}

({double u, double v}) oceanEdgeUv(OceanPatchSide side, double t) =>
    switch (side) {
      OceanPatchSide.south => (u: t, v: 0),
      OceanPatchSide.east => (u: 1, v: t),
      OceanPatchSide.north => (u: 1 - t, v: 1),
      OceanPatchSide.west => (u: 0, v: 1 - t),
    };

/// Bounds the numerical range used by cube projection and curvature estimates.
void validateOceanEllipsoid(Ellipsoid ellipsoid) {
  if (ellipsoid.minimumRadius < 1e-3 ||
      ellipsoid.maximumRadius > 1e12 ||
      ellipsoid.maximumRadius / ellipsoid.minimumRadius > 100) {
    throw ArgumentError(
      'Ocean ellipsoid radii require 1 mm..1e12 m and aspect ratio at most 100.',
    );
  }
}
