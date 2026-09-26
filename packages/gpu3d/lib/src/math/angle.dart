import 'dart:math' as math;

abstract final class Angle {
  /// Converts degrees to the radians used by scene transforms and cameras.
  static double degrees(double value) {
    if (!value.isFinite) throw ArgumentError.value(value, 'degrees');
    return value * math.pi / 180;
  }
}
