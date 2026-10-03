part of '../../zyren_game.dart';

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
        wheels.map((w) => w.mount).toSet().length != wheels.length ||
        !wheels.any((w) => w.driven) ||
        !wheels.any((w) => w.steering) ||
        !_vehicleDefinitionIn(mass, 1, 100000) ||
        !_vehicleDefinitionIn(wheelbase, .1, 50) ||
        !_vehicleDefinitionIn(trackWidth, .1, 30) ||
        !_vehicleDefinitionIn(engineForce, 0, 1e7) ||
        !_vehicleDefinitionIn(brakeForce, 0, 1e7) ||
        !_vehicleDefinitionIn(maxSteerAngle, .001, 1.2) ||
        !_vehicleDefinitionIn(maxSpeed, .1, 150) ||
        !_vehicleDefinitionIn(tireFriction, 0, 5) ||
        !_vehicleDefinitionIn(lostControlBrake, 0, 1)) {
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
      mass: _vehicleDefinitionNumber(json['mass']),
      wheelbase: _vehicleDefinitionNumber(json['wheelbase']),
      trackWidth: _vehicleDefinitionNumber(json['trackWidth']),
      engineForce: _vehicleDefinitionNumber(json['engineForce']),
      brakeForce: _vehicleDefinitionNumber(json['brakeForce']),
      maxSteerAngle: _vehicleDefinitionNumber(json['maxSteerAngle']),
      maxSpeed: _vehicleDefinitionNumber(json['maxSpeed']),
      tireFriction: _vehicleDefinitionNumber(json['tireFriction']),
      lostControlBrake: _vehicleDefinitionNumber(json['lostControlBrake']),
    );
  }
}
