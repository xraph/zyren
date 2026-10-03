part of '../../zyren_game_native.dart';

/// Wheel mounts are chassis-local metres; rates use N/m and N s/m.
final class WheelDefinition {
  final String id;
  final Vec3 mount;
  final bool steering, driven;
  final double radius,
      restLength,
      travel,
      springRate,
      damping,
      maxSuspensionForce;
  WheelDefinition({
    required this.id,
    required this.mount,
    this.steering = false,
    this.driven = true,
    this.radius = .3,
    this.restLength = .4,
    this.travel = .2,
    this.springRate = 30000,
    this.damping = 3000,
    this.maxSuspensionForce = 10000,
  }) {
    if (id.isEmpty ||
        id.length > 64 ||
        !mount.isFinite ||
        mount.length > 100 ||
        !_vehicleIn(radius, .01, 5) ||
        !_vehicleIn(restLength, .01, 10) ||
        !_vehicleIn(travel, .001, restLength) ||
        !_vehicleIn(springRate, 1, 1e7) ||
        !_vehicleIn(damping, 0, 1e6) ||
        !_vehicleIn(maxSuspensionForce, 1, 1e7)) {
      throw ArgumentError('Invalid wheel geometry or suspension units.');
    }
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'mount': mount.storage,
    'steering': steering,
    'driven': driven,
    'radius': radius,
    'restLength': restLength,
    'travel': travel,
    'springRate': springRate,
    'damping': damping,
    'maxSuspensionForce': maxSuspensionForce,
  };
  factory WheelDefinition.fromJson(Map<String, Object?> json) {
    final mount = json['mount'];
    if (mount is! List ||
        mount.length != 3 ||
        json['id'] is! String ||
        json['steering'] is! bool ||
        json['driven'] is! bool) {
      throw const FormatException('Invalid wheel record.');
    }
    return WheelDefinition(
      id: json['id'] as String,
      mount: Vec3(
        _vehicleNumber(mount[0]),
        _vehicleNumber(mount[1]),
        _vehicleNumber(mount[2]),
      ),
      steering: json['steering'] as bool,
      driven: json['driven'] as bool,
      radius: _vehicleNumber(json['radius']),
      restLength: _vehicleNumber(json['restLength']),
      travel: _vehicleNumber(json['travel']),
      springRate: _vehicleNumber(json['springRate']),
      damping: _vehicleNumber(json['damping']),
      maxSuspensionForce: _vehicleNumber(json['maxSuspensionForce']),
    );
  }
}

bool _vehicleIn(double value, double min, double max) =>
    value.isFinite && value >= min && value <= max;
double _vehicleNumber(Object? value) {
  if (value is! num || !value.toDouble().isFinite) {
    throw const FormatException('Expected finite vehicle number.');
  }
  return value.toDouble();
}
