part of '../../zyren_game_native.dart';

final class WheelTelemetry {
  final String id;
  final bool grounded;
  final double suspensionLength,
      suspensionForce,
      normalLoad,
      friction,
      steeringAngle,
      rotation,
      longitudinalSpeed,
      lateralSpeed;
  final Vec3 tireForce;
  final Vec3? contact;
  final int? contactBody;
  const WheelTelemetry({
    required this.id,
    required this.grounded,
    required this.suspensionLength,
    required this.suspensionForce,
    required this.normalLoad,
    required this.friction,
    required this.steeringAngle,
    required this.rotation,
    required this.longitudinalSpeed,
    required this.lateralSpeed,
    required this.tireForce,
    this.contact,
    this.contactBody,
  });
}

/// The wheel forces describe the step just solved; chassis pose is post-physics.
final class VehicleTelemetry {
  final int tick, gear;
  final PhysicsPose pose;
  final Vec3 velocity;
  final VehicleIntent appliedIntent;
  final List<WheelTelemetry> wheels;
  VehicleTelemetry({
    required this.tick,
    required this.gear,
    required this.pose,
    required this.velocity,
    required this.appliedIntent,
    required List<WheelTelemetry> wheels,
  }) : wheels = List.unmodifiable(wheels);
  int get groundedWheels => wheels.where((w) => w.grounded).length;
}
