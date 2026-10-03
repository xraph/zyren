import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'geodesy.dart';

/// An Earth-fixed camera pose. [up] is the rolled world-space camera up axis;
/// [surfaceUp] is the unrolled ellipsoid normal returned separately upstream.
final class GeospatialCameraPose {
  final Vec3 position, target, up, surfaceUp;
  final Quat quaternion;
  final GeoPerspectiveLens? lens;
  const GeospatialCameraPose({
    required this.position,
    required this.target,
    required this.up,
    required this.surfaceUp,
    required this.quaternion,
    this.lens,
  });

  factory GeospatialCameraPose.fromCamera(Camera camera) =>
      GeospatialCameraPose(
        position: camera.position,
        target: camera.target,
        up: camera.up,
        surfaceUp: camera.up,
        quaternion: _poseRotation(camera.position, camera.target, camera.up),
        lens: camera is PerspectiveCamera
            ? GeoPerspectiveLens.fromCamera(camera)
            : null,
      );

  GeospatialCameraPose copyWith({
    Vec3? position,
    Vec3? target,
    Vec3? up,
    Vec3? surfaceUp,
    GeoPerspectiveLens? lens,
  }) {
    final p = position ?? this.position,
        t = target ?? this.target,
        u = up ?? this.up;
    final result = GeospatialCameraPose(
      position: p,
      target: t,
      up: u,
      surfaceUp: surfaceUp ?? this.surfaceUp,
      quaternion: _poseRotation(p, t, u),
      lens: lens ?? this.lens,
    );
    result.validate();
    return result;
  }

  void validate() {
    if (!position.isFinite ||
        !target.isFinite ||
        !up.isFinite ||
        !surfaceUp.isFinite ||
        !quaternion.isFinite ||
        (position - target).length2 < 1e-20 ||
        up.length2 < 1e-20 ||
        up.cross(position - target).length2 < 1e-20) {
      throw ArgumentError('A camera pose needs finite, independent view axes.');
    }
    quaternion.normalized();
    lens?.validate();
  }

  void applyTo(Camera camera) {
    validate();
    if (lens != null && camera is! PerspectiveCamera) {
      throw UnsupportedError('A perspective lens needs a perspective camera.');
    }
    if (lens case final value?) value.applyTo(camera as PerspectiveCamera);
    camera.position = position;
    camera.target = target;
    camera.up = up;
    camera.quaternion = quaternion;
  }
}

/// Optional projection state for managed rigs. PointOfView leaves it unchanged.
final class GeoPerspectiveLens {
  final double near, far, fieldOfView, zoom;
  final DepthStrategy depthStrategy;
  const GeoPerspectiveLens({
    required this.near,
    required this.far,
    required this.fieldOfView,
    this.zoom = 1,
    this.depthStrategy = DepthStrategy.standard,
  });
  factory GeoPerspectiveLens.fromCamera(PerspectiveCamera camera) =>
      GeoPerspectiveLens(
        near: camera.near,
        far: camera.far,
        fieldOfView: camera.fieldOfView,
        zoom: camera.zoom,
        depthStrategy: camera.depthStrategy,
      );
  void validate() {
    if (![near, far, fieldOfView, zoom].every((v) => v.isFinite) ||
        near <= 0 ||
        far <= near ||
        zoom <= 0 ||
        fieldOfView <= 0 ||
        fieldOfView >= math.pi) {
      throw ArgumentError('Invalid perspective lens.');
    }
  }

  void applyTo(PerspectiveCamera camera) {
    validate();
    if (far > camera.far) camera.far = far;
    if (near < camera.near) camera.near = near;
    camera.near = near;
    camera.far = far;
    camera.fieldOfView = fieldOfView;
    camera.zoom = zoom;
    camera.depthStrategy = depthStrategy;
  }
}

Quat _poseRotation(Vec3 position, Vec3 target, Vec3 up) {
  final backward = (position - target).normalized();
  final right = up.cross(backward).normalized();
  return _rotation(right, backward.cross(right), backward);
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
  /// zyren cameras store a world-space up vector and a world-space target.
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
