part of 'orbit_navigation.dart';

/// Free orbital rotation with roll and no world-up pole restriction.
/// Pan, dolly, pinch, damping, save/reset and gesture ownership match orbit.
final class TrackballControls extends OrbitNavigation {
  @override
  String get id => 'zyren.trackball';
  Quat _rotation = Quat.identity;
  TrackballControls({
    super.enabled,
    OrbitLimits? limits,
    super.damping,
    super.rotateSpeed,
    super.panSpeed,
    super.zoomSpeed,
    super.dragBinding,
  }) : super(
         limits: OrbitLimits(
           minDistance: limits?.minDistance ?? .01,
           maxDistance: limits?.maxDistance ?? double.infinity,
           minZoom: limits?.minZoom ?? .01,
           maxZoom: limits?.maxZoom ?? 1000,
         ),
       );
  @override
  bool get _hasMotion => super._hasMotion || _rotation != Quat.identity;

  /// Angles use the camera's current up, right and forward axes, in radians.
  @override
  void rotateBy({double azimuth = 0, double polar = 0, double roll = 0}) {
    if ([azimuth, polar, roll].any((v) => !v.isFinite)) {
      throw ArgumentError('Trackball angles must be finite.');
    }
    final camera = _current();
    if (!enabled) return;
    final forward = (camera.target - camera.position).normalized();
    final right = forward.cross(camera.up).normalized();
    _queue(
      Quat.axisAngle(forward, roll) *
          Quat.axisAngle(right, polar) *
          Quat.axisAngle(camera.up, azimuth),
    );
  }

  /// Arcball points use viewport coordinates centered at zero, with Y upward
  /// and one unit equal to half the shorter viewport dimension.
  void rotateTrackball(Vec2 from, Vec2 to) {
    if (!from.isFinite ||
        !to.isFinite ||
        !from.length2.isFinite ||
        !to.length2.isFinite) {
      throw ArgumentError('Trackball points must be finite.');
    }
    final camera = _current();
    if (!enabled || from == to) return;
    Vec3 project(Vec2 point) {
      final length = point.length2;
      return length <= 1
          ? Vec3(point.x, point.y, math.sqrt(1 - length))
          : Vec3(point.x, point.y, 0).normalized();
    }

    final a = project(from), b = project(to), axis = a.cross(b);
    final back = (camera.position - camera.target).normalized(),
        right = camera.up.cross(back).normalized(),
        up = back.cross(right);
    if (axis.length2 < 1e-20) {
      if (a.dot(b) < 0) {
        final helper = a.x.abs() < .9
            ? const Vec3(1, 0, 0)
            : const Vec3(0, 1, 0);
        final perpendicular = a.cross(helper).normalized();
        _queue(
          Quat.axisAngle(
            right * perpendicular.x +
                up * perpendicular.y +
                back * perpendicular.z,
            math.pi * rotateSpeed,
          ),
        );
      }
      return;
    }
    final world = right * axis.x + up * axis.y + back * axis.z;
    _queue(
      Quat.axisAngle(world, -math.atan2(axis.length, a.dot(b)) * rotateSpeed),
    );
  }

  void _queue(Quat value) {
    _rotation = (value * _rotation).normalized();
    if ((_rotation.x * _rotation.x +
            _rotation.y * _rotation.y +
            _rotation.z * _rotation.z) <
        1e-24) {
      _rotation = Quat.identity;
    }
    _changed();
  }

  @override
  void _rotatePointer(ScenePointerEvent event, double width, double height) {
    final radius = math.min(width, height) / 2;
    Vec2 point(double x, double y) =>
        Vec2((x - width / 2) / radius, (height / 2 - y) / radius);
    rotateTrackball(
      point(event.point.x - event.delta.x, event.point.y - event.delta.y),
      point(event.point.x, event.point.y),
    );
  }

  @override
  void _step(double fraction) {
    var q = _rotation;
    if (q.w < 0) q = Quat(-q.x, -q.y, -q.z, -q.w);
    final vector = Vec3(q.x, q.y, q.z), sine = vector.length;
    if (sine > 1e-12) {
      final angle = 2 * math.atan2(sine, q.w);
      if (angle < 1e-7) fraction = 1;
      final step = Quat.axisAngle(vector, angle * fraction), camera = _camera!;
      final position =
          camera.target + step.rotate(camera.position - camera.target);
      final up = step.rotate(camera.up).normalized();
      if (!position.isFinite) {
        stop();
        throw ArgumentError('Trackball pose overflow.');
      }
      camera.position = position;
      camera.up = up;
      _rotation = fraction == 1
          ? Quat.identity
          : Quat.axisAngle(vector, angle * (1 - fraction));
    } else {
      _rotation = Quat.identity;
    }
    super._step(fraction);
  }

  @override
  void stop() {
    _rotation = Quat.identity;
    super.stop();
  }
}
