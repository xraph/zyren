import 'dart:math' as math;
import 'vec3.dart';

void _parameter(double t) {
  if (!t.isFinite || t < 0 || t > 1) {
    throw ArgumentError.value(t, 't', 'Expected [0, 1].');
  }
}

void _count(int value) {
  if (value < 1 || value > 1000000) {
    throw ArgumentError('Expected 1 to 1000000 subdivisions.');
  }
}

void _controls(Iterable<Vec3> points) {
  if (points.any((p) => !p.isFinite)) {
    throw ArgumentError('Curve points must be finite.');
  }
}

/// A 3D parametric path. Subclasses return finite positions for t in [0, 1].
abstract class Curve3 {
  Vec3 pointAt(double t);
  Vec3 tangentAt(double t) {
    _parameter(t);
    return (pointAt(math.min(1, t + .00001)) - pointAt(math.max(0, t - .00001)))
        .normalized();
  }

  List<Vec3> points({int segments = 32}) {
    _count(segments);
    return List.unmodifiable(
      List.generate(segments + 1, (i) => pointAt(i / segments)),
    );
  }

  CurveSamples sample({int divisions = 200}) =>
      CurveSamples._(points(segments: divisions));
  List<Vec3> spacedPoints({int segments = 32, int divisions = 200}) {
    _count(segments);
    final table = sample(divisions: divisions);
    return List.unmodifiable(
      List.generate(
        segments + 1,
        (i) => pointAt(table.parameterAt(i / segments)),
      ),
    );
  }
}

/// Captured polyline lengths. Sampling is approximate; increase divisions for curvature.
final class CurveSamples {
  final List<Vec3> points;
  late final List<double> cumulativeLengths;
  double get length => cumulativeLengths.last;
  CurveSamples._(this.points) {
    _controls(points);
    final distances = <double>[0];
    for (var i = 1; i < points.length; i++) {
      final value = distances.last + points[i].distanceTo(points[i - 1]);
      if (!value.isFinite) {
        throw ArgumentError('Curve length exceeds finite coordinates.');
      }
      distances.add(value);
    }
    cumulativeLengths = List.unmodifiable(distances);
  }

  /// Maps a distance fraction to the original curve's normalized parameter.
  double parameterAt(double fraction) {
    _parameter(fraction);
    if (fraction == 0 || fraction == 1 || length == 0) return fraction;
    final target = fraction * length;
    var low = 0, high = cumulativeLengths.length - 1;
    while (high - low > 1) {
      final mid = (low + high) ~/ 2;
      if (cumulativeLengths[mid] < target) {
        low = mid;
      } else {
        high = mid;
      }
    }
    final span = cumulativeLengths[high] - cumulativeLengths[low];
    final offset = span == 0 ? 0.0 : (target - cumulativeLengths[low]) / span;
    return (low + offset) / (points.length - 1);
  }
}

final class LineCurve3 extends Curve3 {
  final Vec3 start, end;
  LineCurve3(this.start, this.end) {
    _controls([start, end]);
  }
  @override
  Vec3 pointAt(double t) {
    _parameter(t);
    return start * (1 - t) + end * t;
  }

  @override
  Vec3 tangentAt(double t) {
    _parameter(t);
    return (end - start).normalized();
  }
}

final class QuadraticBezierCurve3 extends Curve3 {
  final Vec3 start, control, end;
  QuadraticBezierCurve3(this.start, this.control, this.end) {
    _controls([start, control, end]);
  }
  @override
  Vec3 pointAt(double t) {
    _parameter(t);
    final s = 1 - t;
    return start * (s * s) + control * (2 * s * t) + end * (t * t);
  }

  @override
  Vec3 tangentAt(double t) {
    _parameter(t);
    final derivative =
        (control - start) * (2 * (1 - t)) + (end - control) * (2 * t);
    return derivative.length2 == 0
        ? super.tangentAt(t)
        : derivative.normalized();
  }
}

final class CubicBezierCurve3 extends Curve3 {
  final Vec3 start, control1, control2, end;
  CubicBezierCurve3(this.start, this.control1, this.control2, this.end) {
    _controls([start, control1, control2, end]);
  }
  @override
  Vec3 pointAt(double t) {
    _parameter(t);
    final s = 1 - t;
    return start * (s * s * s) +
        control1 * (3 * s * s * t) +
        control2 * (3 * s * t * t) +
        end * (t * t * t);
  }

  @override
  Vec3 tangentAt(double t) {
    _parameter(t);
    final s = 1 - t;
    final derivative =
        (control1 - start) * (3 * s * s) +
        (control2 - control1) * (6 * s * t) +
        (end - control2) * (3 * t * t);
    return derivative.length2 == 0
        ? super.tangentAt(t)
        : derivative.normalized();
  }
}

enum CatmullRomType { centripetal, chordal, uniform }

/// Interpolates captured control points. Tension applies to the uniform variant.
final class CatmullRomCurve3 extends Curve3 {
  final List<Vec3> controlPoints;
  final bool closed;
  final CatmullRomType type;
  final double tension;
  CatmullRomCurve3(
    Iterable<Vec3> points, {
    this.closed = false,
    this.type = CatmullRomType.centripetal,
    this.tension = .5,
  }) : controlPoints = _capture(points) {
    if (controlPoints.length < (closed ? 3 : 2) ||
        !tension.isFinite ||
        tension < 0 ||
        tension > 1) {
      throw ArgumentError('Invalid Catmull-Rom control count or tension.');
    }
  }
  static List<Vec3> _capture(Iterable<Vec3> points) {
    final result = <Vec3>[];
    for (final point in points) {
      if (!point.isFinite || result.length >= 1000000) {
        throw ArgumentError('Invalid or excessive curve controls.');
      }
      result.add(point);
    }
    return List.unmodifiable(result);
  }

  Vec3 _point(int i) {
    final n = controlPoints.length;
    if (closed) return controlPoints[i % n];
    if (i < 0) return controlPoints[0] * 2 - controlPoints[1];
    if (i >= n) return controlPoints[n - 1] * 2 - controlPoints[n - 2];
    return controlPoints[i];
  }

  @override
  Vec3 pointAt(double t) {
    _parameter(t);
    if (t == 1) return closed ? controlPoints.first : controlPoints.last;
    final position =
            t * (closed ? controlPoints.length : controlPoints.length - 1),
        i = position.floor(),
        u = position - i;
    final a = _point(i - 1),
        b = _point(i),
        c = _point(i + 1),
        d = _point(i + 2);
    Vec3 m1, m2;
    if (type == CatmullRomType.uniform) {
      m1 = (c - a) * tension;
      m2 = (d - b) * tension;
    } else {
      final power = type == CatmullRomType.centripetal ? .25 : .5;
      var before = math.pow((b - a).length2, power).toDouble();
      var middle = math.pow((c - b).length2, power).toDouble();
      var after = math.pow((d - c).length2, power).toDouble();
      if (middle < .0001) middle = 1;
      if (before < .0001) before = middle;
      if (after < .0001) after = middle;
      m1 =
          ((b - a) / before - (c - a) / (before + middle) + (c - b) / middle) *
          middle;
      m2 =
          ((c - b) / middle - (d - b) / (middle + after) + (d - c) / after) *
          middle;
    }
    final u2 = u * u, u3 = u2 * u;
    return b * (2 * u3 - 3 * u2 + 1) +
        m1 * (u3 - 2 * u2 + u) +
        c * (-2 * u3 + 3 * u2) +
        m2 * (u3 - u2);
  }

  @override
  Vec3 tangentAt(double t) {
    _parameter(t);
    if (!closed) return super.tangentAt(t);
    return (pointAt((t + .00001) % 1) - pointAt((t - .00001) % 1)).normalized();
  }
}
