import 'package:zyren/zyren.dart';

/// Distributed drag coefficients per submerged cubic metre. Linear has units
/// N s / m^4, quadratic N s^2 / m^5, angular N s / m^2.
final class BuoyancyDrag {
  final double linear, quadratic, angular;
  BuoyancyDrag({this.linear = 0, this.quadratic = 0, this.angular = 0}) {
    if ([
      linear,
      quadratic,
      angular,
    ].any((v) => !v.isFinite || v < 0 || v > 1e12)) {
      throw ArgumentError('Drag coefficients must be finite and in [0,1e12].');
    }
  }
  Vec3 force(Vec3 relativeVelocity, double volume) =>
      relativeVelocity *
      (-volume * (linear + quadratic * relativeVelocity.length));
}
