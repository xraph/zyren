part of '../../zyren_game_native.dart';

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

bool _vehicleIn(double value, double min, double max) =>
    value.isFinite && value >= min && value <= max;
