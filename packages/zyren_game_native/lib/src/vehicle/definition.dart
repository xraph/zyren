part of '../../zyren_game_native.dart';

/// Arcade ray-wheel handling, in metres, kilograms, seconds and radians.
final class VehicleDefinition {
  final List<WheelDefinition> wheels;
  final double mass,
      wheelbase,
      trackWidth,
      engineForce,
      brakeForce,
      maxSteerAngle,
      maxSpeed,
      tireFriction,
      lostControlBrake;
  VehicleDefinition({
    required List<WheelDefinition> wheels,
    this.mass = 400,
    this.wheelbase = 2,
    this.trackWidth = 1.4,
    this.engineForce = 4000,
    this.brakeForce = 8000,
    this.maxSteerAngle = .45,
    this.maxSpeed = 25,
    this.tireFriction = 1,
    this.lostControlBrake = 1,
  }) : wheels = List.unmodifiable(wheels) {
    if (wheels.length < 4 ||
        wheels.length > 8 ||
        wheels.length.isOdd ||
        wheels.map((w) => w.id).toSet().length != wheels.length ||
        !wheels.any((w) => w.driven) ||
        !wheels.any((w) => w.steering) ||
        !_vehicleIn(mass, 1, 100000) ||
        !_vehicleIn(wheelbase, .1, 50) ||
        !_vehicleIn(trackWidth, .1, 30) ||
        !_vehicleIn(engineForce, 0, 1e7) ||
        !_vehicleIn(brakeForce, 0, 1e7) ||
        !_vehicleIn(maxSteerAngle, .001, 1.2) ||
        !_vehicleIn(maxSpeed, .1, 150) ||
        !_vehicleIn(tireFriction, 0, 5) ||
        !_vehicleIn(lostControlBrake, 0, 1)) {
      throw ArgumentError('Invalid vehicle geometry or handling limits.');
    }
    final minZ = wheels.map((w) => w.mount.z).reduce(math.min);
    final maxZ = wheels.map((w) => w.mount.z).reduce(math.max);
    final minX = wheels.map((w) => w.mount.x).reduce(math.min);
    final maxX = wheels.map((w) => w.mount.x).reduce(math.max);
    if ((maxZ - minZ - wheelbase).abs() > 1e-6 ||
        (maxX - minX - trackWidth).abs() > 1e-6 ||
        wheelbase / math.tan(maxSteerAngle) <= trackWidth / 2 + .01 ||
        minX >= 0 ||
        maxX <= 0 ||
        minZ >= 0 ||
        maxZ <= 0 ||
        wheels
            .where((w) => w.steering)
            .any((w) => (w.mount.z - maxZ).abs() > 1e-6)) {
      throw ArgumentError(
        'Wheelbase, track and front steering mounts disagree.',
      );
    }
  }
  Map<String, Object?> toJson() => {
    'version': 1,
    'mass': mass,
    'wheelbase': wheelbase,
    'trackWidth': trackWidth,
    'engineForce': engineForce,
    'brakeForce': brakeForce,
    'maxSteerAngle': maxSteerAngle,
    'maxSpeed': maxSpeed,
    'tireFriction': tireFriction,
    'lostControlBrake': lostControlBrake,
    'wheels': wheels.map((w) => w.toJson()).toList(),
  };
  factory VehicleDefinition.fromJson(Map<String, Object?> json) {
    final wheels = json['wheels'];
    if (json['version'] != 1 ||
        wheels is! List ||
        wheels.length > 8 ||
        wheels.any((w) => w is! Map<String, Object?>)) {
      throw const FormatException(
        'Invalid vehicle definition version or wheels.',
      );
    }
    return VehicleDefinition(
      wheels: wheels
          .map((w) => WheelDefinition.fromJson(w as Map<String, Object?>))
          .toList(),
      mass: _vehicleNumber(json['mass']),
      wheelbase: _vehicleNumber(json['wheelbase']),
      trackWidth: _vehicleNumber(json['trackWidth']),
      engineForce: _vehicleNumber(json['engineForce']),
      brakeForce: _vehicleNumber(json['brakeForce']),
      maxSteerAngle: _vehicleNumber(json['maxSteerAngle']),
      maxSpeed: _vehicleNumber(json['maxSpeed']),
      tireFriction: _vehicleNumber(json['tireFriction']),
      lostControlBrake: _vehicleNumber(json['lostControlBrake']),
    );
  }
}

final class VehicleIntent {
  final double steer, throttle, brake;
  final bool handbrake;
  final int? gearRequest;
  const VehicleIntent({
    this.steer = 0,
    this.throttle = 0,
    this.brake = 0,
    this.handbrake = false,
    this.gearRequest,
  });
  void validate() {
    if (!_vehicleIn(steer, -1, 1) ||
        !_vehicleIn(throttle, 0, 1) ||
        !_vehicleIn(brake, 0, 1) ||
        gearRequest != null && ![-1, 0, 1].contains(gearRequest)) {
      throw ArgumentError('Vehicle input exceeds handling bounds.');
    }
  }
}
