import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'geodesy.dart';

/// An Earth-fixed camera pose. [up] is the rolled world-space camera up axis;
/// [surfaceUp] is the unrolled ellipsoid normal returned separately upstream.
final class GeospatialCameraPose {
  final Vec3 position, target, up, surfaceUp;
  final Quat quaternion;
  const GeospatialCameraPose({
    required this.position,
    required this.target,
    required this.up,
    required this.surfaceUp,
    required this.quaternion,
  });

  void applyTo(Camera camera) {
    camera.position = position;
    camera.target = target;
    camera.up = up;
    camera.quaternion = quaternion;
  }
}

/// Heading is measured from local east toward north, in radians. Positive
/// pitch looks above the horizon. Distance is in metres from the target.
final class PointOfView {
  static const epsilon = 1e-6;
  final double distance, heading, pitch, roll;
  PointOfView({
    double distance = 0,
    this.heading = 0,
    double pitch = 0,
    this.roll = 0,
  }) : distance = math.max(distance, epsilon),
       pitch = pitch.clamp(-math.pi / 2 + epsilon, math.pi / 2 - epsilon) {
    if ([distance, heading, pitch, roll].any((v) => !v.isFinite)) {
      throw ArgumentError('Point of view values must be finite.');
    }
  }

  PointOfView copyWith({
    double? distance,
    double? heading,
    double? pitch,
    double? roll,
  }) => PointOfView(
    distance: distance ?? this.distance,
    heading: heading ?? this.heading,
    pitch: pitch ?? this.pitch,
    roll: roll ?? this.roll,
  );

  GeospatialCameraPose decompose(
    Vec3 target, {
    Ellipsoid ellipsoid = Ellipsoid.wgs84,
  }) {
    final basis = ellipsoid.eastNorthUpVectors(target);
    final direction =
        ((basis.east * math.cos(heading) + basis.north * math.sin(heading)) *
                    math.cos(pitch) +
                basis.up * math.sin(pitch))
            .normalized();
    final eye = target - direction * distance;
    final rolledUp = roll == 0
        ? basis.up
        : Quat.axisAngle(direction, roll).rotate(basis.up);
    final backward = (eye - target).normalized();
    final right = rolledUp.cross(backward).normalized();
    final up = backward.cross(right);
    return GeospatialCameraPose(
      position: eye,
      target: target,
      up: up,
      surfaceUp: basis.up,
      quaternion: _rotation(right, up, backward),
    );
  }

  /// Reconstructs the view at the first ellipsoid hit. Returns null for sky.
  /// gpu3d cameras store a world-space up vector and a world-space target.
  static ({PointOfView view, Vec3 target})? fromCamera(
    Camera camera, {
    Ellipsoid ellipsoid = Ellipsoid.wgs84,
  }) {
    final direction = (camera.target - camera.position).normalized();
    final target = ellipsoid.intersectRay(camera.position, direction);
    if (target == null) return null;
    final basis = ellipsoid.eastNorthUpVectors(target);
    final projectedCameraUp = (camera.up - direction * camera.up.dot(direction))
        .normalized();
    final surfaceProjection = basis.up - direction * basis.up.dot(direction);
    // A vertical view has no projected horizon from which to measure roll.
    // Three's zero-vector normalization leaves zero; atan2 then returns zero.
    final projectedSurfaceUp = surfaceProjection.length2 == 0
        ? Vec3.zero
        : surfaceProjection.normalized();
    return (
      view: PointOfView(
        distance: camera.position.distanceTo(target),
        heading: math.atan2(
          basis.north.dot(direction),
          basis.east.dot(direction),
        ),
        pitch: math.asin(basis.up.dot(direction).clamp(-1.0, 1.0)),
        roll: math.atan2(
          direction.dot(projectedSurfaceUp.cross(projectedCameraUp)),
          projectedSurfaceUp.dot(projectedCameraUp),
        ),
      ),
      target: target,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PointOfView &&
      distance == other.distance &&
      heading == other.heading &&
      pitch == other.pitch &&
      roll == other.roll;
  @override
  int get hashCode => Object.hash(distance, heading, pitch, roll);
}

Quat _rotation(Vec3 x, Vec3 y, Vec3 z) {
  final trace = x.x + y.y + z.z;
  if (trace > 0) {
    final s = .5 / math.sqrt(trace + 1);
    return Quat(
      (y.z - z.y) * s,
      (z.x - x.z) * s,
      (x.y - y.x) * s,
      .25 / s,
    ).normalized();
  }
  if (x.x > y.y && x.x > z.z) {
    final s = 2 * math.sqrt(1 + x.x - y.y - z.z);
    return Quat(
      .25 * s,
      (y.x + x.y) / s,
      (z.x + x.z) / s,
      (y.z - z.y) / s,
    ).normalized();
  }
  if (y.y > z.z) {
    final s = 2 * math.sqrt(1 + y.y - x.x - z.z);
    return Quat(
      (y.x + x.y) / s,
      .25 * s,
      (z.y + y.z) / s,
      (z.x - x.z) / s,
    ).normalized();
  }
  final s = 2 * math.sqrt(1 + z.z - x.x - y.y);
  return Quat(
    (z.x + x.z) / s,
    (z.y + y.z) / s,
    .25 * s,
    (x.y - y.x) / s,
  ).normalized();
}
