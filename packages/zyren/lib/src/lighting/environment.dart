part of '../resources/resource_scope.dart';

/// Immutable environment settings captured for one frame. Rotation moves the
/// environment from its local axes into world axes; intensity scales radiance.
final class Environment {
  final EnvironmentMap map;
  final double intensity;
  final Quat rotation;

  /// Adapter tokens for this immutable selection. Frame leases retain the map.
  List<Uint8List> encodeForDevice(EnvironmentDevice device) => [
    for (final texture in [map.diffuse, map.specular, map.brdf])
      if (texture.isClosed || !identical(texture._scope._device, device))
        throw ArgumentError('Environment needs a live owner on this device.')
      else
        device.encodeResourceKey(texture._key),
  ];
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
