part of '../zyren_3d_tiles.dart';

/// Optional world-space rejection. Return false only for fully hidden bounds.
typedef TileVisibilityPolicy =
    bool Function(TileBounds3D bounds, Camera camera);

/// Selection settles at the configured pixel error after navigation stops.
final class Tiles3DMotionPolicy {
  final Duration prediction, settle;
  final double movingErrorScale, adjacentScale;
  const Tiles3DMotionPolicy({
    this.prediction = const Duration(milliseconds: 200),
    this.settle = const Duration(milliseconds: 300),
    this.movingErrorScale = 2,
    this.adjacentScale = 1.15,
  });

  void _validate() {
    if (prediction <= Duration.zero ||
        prediction > const Duration(seconds: 1) ||
        settle <= Duration.zero ||
        settle > const Duration(seconds: 2) ||
        !movingErrorScale.isFinite ||
        movingErrorScale < 1 ||
        movingErrorScale > 4 ||
        !adjacentScale.isFinite ||
        adjacentScale < 1 ||
        adjacentScale > 1.5) {
      throw ArgumentError(
        'Motion selection needs bounded prediction and recovery.',
      );
    }
  }
}

final class _TileMotion {
  final Tiles3DMotionPolicy policy;
  Vec3? _position, _forward, _velocity;
  Duration? _sampled, _moved;
  double scale = 1;
  Camera? predicted;
  bool pending = false;
  _TileMotion(this.policy);

  bool update(Camera camera, Duration time) {
    final oldScale = scale, oldPrediction = predicted;
    final forward = (camera.target - camera.position).normalized();
    final changed =
        _position != null &&
        (_position != camera.position || _forward != forward);
    if (_sampled != null && time < _sampled!) {
      _sampled = null;
      _moved = null;
      _velocity = null;
      predicted = null;
    }
    if (changed && _sampled != null) {
      final dt = (time - _sampled!).inMicroseconds / 1e6;
      final shift = camera.position - _position!;
      final distance = math.max(1.0, (camera.target - camera.position).length);
      final turn = math.acos(forward.dot(_forward!).clamp(-1.0, 1.0));
      final reversal = _velocity != null && shift.dot(_velocity!) < 0;
      predicted = null;
      // Teleports, large turns and reversals invalidate the old extrapolation.
      if (dt > 0 &&
          dt <= .5 &&
          turn < .6 &&
          shift.length < distance &&
          !reversal) {
        final factor = math.min(
          policy.prediction.inMicroseconds / 1e6 / dt,
          3.0,
        );
        Vec3 bounded(Vec3 v, double limit) =>
            v.length > limit ? v.normalized() * limit : v;
        final offset = bounded(shift * factor, distance * .25);
        final direction =
            (forward + bounded((forward - _forward!) * factor, .35))
                .normalized();
        final position = camera.position + offset;
        predicted = _cameraCopy(
          camera,
          position,
          position + direction * distance,
        );
      }
      _velocity = shift;
      _moved = time;
      // Continuous attack avoids an abrupt change in refinement threshold.
      scale += (policy.movingErrorScale - scale) * (dt / .08).clamp(0.0, 1.0);
    } else if (_moved != null) {
      final age = time - _moved!;
      if (age >= policy.prediction) predicted = null;
      final fraction = (age.inMicroseconds / policy.settle.inMicroseconds)
          .clamp(0.0, 1.0);
      scale = math.min(
        scale,
        1 + (policy.movingErrorScale - 1) * (1 - fraction),
      );
    }
    _position = camera.position;
    _forward = forward;
    _sampled = time;
    pending = _moved != null && time - _moved! < policy.settle;
    return scale != oldScale || !identical(predicted, oldPrediction) || changed;
  }

  Camera _cameraCopy(Camera source, Vec3 position, Vec3 target) =>
      switch (source) {
        PerspectiveCamera c => PerspectiveCamera(
          position: position,
          target: target,
          up: c.up,
          fieldOfView: c.fieldOfView,
          near: c.near,
          far: c.far,
          zoom: c.zoom,
          depthStrategy: c.depthStrategy,
        ),
        OrthographicCamera c => OrthographicCamera(
          position: position,
          target: target,
          up: c.up,
          left: c.left,
          right: c.right,
          top: c.top,
          bottom: c.bottom,
          near: c.near,
          far: c.far,
          zoom: c.zoom,
          depthStrategy: c.depthStrategy,
        ),
        _ => throw UnsupportedError(
          'Motion selection requires a projection camera.',
        ),
      };
}
