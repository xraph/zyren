import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'time_scale.dart';
export 'time_scale.dart';
part 'earth_coefficients.dart';
part 'lunar_series.dart';
part 'rotations.dart';

const _deg = 0.017453292519943296;
const _arcsec = 4.848136811095359935899141e-6;
const _tau = 2 * math.pi;
const _arcPerRad = 3600 * (180 / math.pi);
const _kmPerAu = 1.4959787069098932e8;

/// J2000 equatorial (ECI) and Earth-fixed (ECEF) directions, without refraction
/// or aberration, matching three-geospatial and Astronomy Engine 2.1.19.
final class CelestialDirections {
  final AstronomicalTime time;
  final Vec3 sunECI, moonECI, sunECEF, moonECEF;
  final Mat4 eciToEcef, moonFixedToEci;

  /// Distances from Earth's centre, independent of the optional observer.
  final double siderealHours, sunDistanceMeters, moonDistanceMeters;
  CelestialDirections._(
    this.time,
    this.sunECI,
    this.moonECI,
    this.sunECEF,
    this.moonECEF,
    this.eciToEcef,
    this.moonFixedToEci,
    this.siderealHours,
    this.sunDistanceMeters,
    this.moonDistanceMeters,
  );
  factory CelestialDirections.at(DateTime date, {Vec3? observerECEF}) {
    if (observerECEF != null &&
        (!observerECEF.isFinite || observerECEF.length > 1e12)) {
      throw ArgumentError(
        'Observer must be finite ECEF metres within 1e12 metres.',
      );
    }
    final time = AstronomicalTime(date);
    final precession = _precession(time), nutation = _nutation(time);
    final sidereal = _sidereal(time);
    final angle = -15 * sidereal * _deg,
        c = math.cos(angle),
        s = math.sin(angle);
    final eciToEcef =
        Mat4([c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]) *
        nutation *
        precession;
    final sun = -_earthPosition(time);
    final moon = _LunarSeries(time).calculate();
    final r = moon.distance * math.cos(moon.latitude);
    final eclip = Vec3(
      r * math.cos(moon.longitude),
      r * math.sin(moon.longitude),
      moon.distance * math.sin(moon.latitude),
    );
    final obliquity = _meanObliquity(time) * _deg;
    final equator = Vec3(
      eclip.x,
      eclip.y * math.cos(obliquity) - eclip.z * math.sin(obliquity),
      eclip.y * math.sin(obliquity) + eclip.z * math.cos(obliquity),
    );
    final moonEci = _inverseRotate(precession, equator);
    final observer = observerECEF == null
        ? Vec3.zero
        : _inverseRotate(eciToEcef, observerECEF) * (.001 / _kmPerAu);
    final sunDirection = (sun - observer).normalized(),
        moonDirection = (moonEci - observer).normalized();
    return CelestialDirections._(
      time,
      sunDirection,
      moonDirection,
      _rotate(eciToEcef, sunDirection),
      _rotate(eciToEcef, moonDirection),
      eciToEcef,
      _moonFixed(time),
      sidereal,
      sun.length * _kmPerAu * 1000,
      moonEci.length * _kmPerAu * 1000,
    );
  }
}

Vec3 _rotate(Mat4 rotation, Vec3 p) {
  final m = rotation.storage;
  return Vec3(
    m[0] * p.x + m[4] * p.y + m[8] * p.z,
    m[1] * p.x + m[5] * p.y + m[9] * p.z,
    m[2] * p.x + m[6] * p.y + m[10] * p.z,
  );
}

Vec3 _inverseRotate(Mat4 rotation, Vec3 p) {
  final m = rotation.storage;
  return Vec3(
    m[0] * p.x + m[1] * p.y + m[2] * p.z,
    m[4] * p.x + m[5] * p.y + m[6] * p.z,
    m[8] * p.x + m[9] * p.y + m[10] * p.z,
  );
}

Vec3 _earthPosition(AstronomicalTime time) {
  final t = time.ttDays / 365250;
  double evaluate(List<List<List<double>>> formula, bool angle) {
    var power = 1.0, coordinate = 0.0;
    for (final series in formula) {
      var sum = 0.0;
      for (final term in series) {
        sum += term[0] * math.cos(term[1] + t * term[2]);
      }
      var increment = power * sum;
      if (angle) increment = increment.remainder(_tau);
      coordinate += increment;
      power *= t;
    }
    return coordinate;
  }

  final lon = evaluate(_earth[0], true),
      lat = evaluate(_earth[1], false),
      radius = evaluate(_earth[2], false);
  final r = radius * math.cos(lat),
      x = r * math.cos(lon),
      y = r * math.sin(lon),
      z = radius * math.sin(lat);
  return Vec3(
    x + .000000440360 * y - .000000190919 * z,
    -.000000479966 * x + .917482137087 * y - .397776982902 * z,
    .397776982902 * y + .917482137087 * z,
  );
}

double _sidereal(AstronomicalTime time) {
  final t = time.ttDays / 36525;
  final nut = _nutationAngles(time);
  final eqeq = nut.dpsi * math.cos(_meanObliquity(time) * _deg);
  final theta =
      360 *
      ((.7790572732640 +
              .00273781191135448 * time.utDays +
              time.utDays.remainder(1))
          .remainder(1));
  final st =
      eqeq +
      .014506 +
      ((((-.0000000368 * t - .000029956) * t - .00000044) * t + 1.3915817) * t +
              4612.156534) *
          t;
  return ((st / 3600 + (theta < 0 ? theta + 360 : theta)) % 360) / 15;
}
