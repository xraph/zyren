part of '../resources/resource_scope.dart';

/// Immutable environment settings captured for one frame. Rotation moves the
/// environment from its local axes into world axes; intensity scales radiance.
final class Environment {
  final EnvironmentMap map;
  final double intensity;
  final Quat rotation;
  Environment({
    required this.map,
    this.intensity = 1,
    Quat rotation = Quat.identity,
  }) : rotation = rotation.normalized() {
    if (map.isClosed) throw StateError('Environment map has closed.');
    if (!intensity.isFinite || intensity < 0 || intensity > 1e6) {
      throw ArgumentError.value(
        intensity,
        'intensity',
        'Must be finite and in [0, 1000000].',
      );
    }
  }
}
