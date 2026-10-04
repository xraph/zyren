import 'dart:math' as math;
import 'package:zyren/zyren.dart';

/// A half-space in metres, relative to the containing volume's anchor.
/// Water is inside when dot(normal, position - anchor) <= offset.
final class OceanWaterPlane {
  final Vec3 normal;
  final double offset;
  OceanWaterPlane(Vec3 normal, double offset)
    : normal = normal.normalized(),
      offset = offset / normal.length {
    if (!normal.isFinite ||
        normal.length < 1e-12 ||
        !normal.length.isFinite ||
        !this.offset.isFinite) {
      throw ArgumentError('Water planes need a finite nonzero normal.');
    }
  }
}

/// Distance along a unit ray, clipped to the configured water volume.
final class OceanWaterSegment {
  final double start, end;
  const OceanWaterSegment(this.start, this.end);
  double get metres => math.max(0, end - start);
  static const empty = OceanWaterSegment(0, 0);
}

/// Convex bounds intersected with the rendered water surface. With no planes,
/// the surface and nearest scene geometry supply the limits. You can use a box
/// for a tank, pool or bounded ocean region, without treating air as water.
final class OceanWaterVolume {
  final Vec3 anchor;
  final List<OceanWaterPlane> planes;
  OceanWaterVolume({
    this.anchor = Vec3.zero,
    Iterable<OceanWaterPlane> planes = const [],
  }) : planes = List.unmodifiable(planes) {
    if (!anchor.isFinite || this.planes.length > 6) {
      throw ArgumentError(
        'Water volumes allow up to six planes and a finite anchor.',
      );
    }
  }
  factory OceanWaterVolume.box({required Vec3 min, required Vec3 max}) {
    if (!min.isFinite ||
        !max.isFinite ||
        min.x >= max.x ||
        min.y >= max.y ||
        min.z >= max.z) {
      throw ArgumentError('Water box bounds must be finite and increasing.');
    }
    final center = min * .5 + max * .5, half = max * .5 - min * .5;
    return OceanWaterVolume(
      anchor: center,
      planes: [
        OceanWaterPlane(const Vec3(1, 0, 0), half.x),
        OceanWaterPlane(const Vec3(-1, 0, 0), half.x),
        OceanWaterPlane(const Vec3(0, 1, 0), half.y),
        OceanWaterPlane(const Vec3(0, -1, 0), half.y),
        OceanWaterPlane(const Vec3(0, 0, 1), half.z),
        OceanWaterPlane(const Vec3(0, 0, -1), half.z),
      ],
    );
  }

  OceanWaterSegment clip(
    Vec3 origin,
    Vec3 direction, {
    required double maximumDistance,
    double start = 0,
  }) {
    if (!origin.isFinite ||
        !direction.isFinite ||
        (direction.length - 1).abs() > 1e-8 ||
        !maximumDistance.isFinite ||
        maximumDistance < 0 ||
        !start.isFinite ||
        start < 0 ||
        start > maximumDistance) {
      throw ArgumentError(
        'Volume clipping requires a unit ray and finite distances.',
      );
    }
    var low = start, high = maximumDistance;
    final local = origin - anchor;
    for (final plane in planes) {
      final denominator = plane.normal.dot(direction);
      final numerator = plane.offset - plane.normal.dot(local);
      if (denominator.abs() < 1e-12) {
        if (numerator < 0) return OceanWaterSegment.empty;
      } else if (denominator > 0) {
        high = math.min(high, numerator / denominator);
      } else {
        low = math.max(low, numerator / denominator);
      }
      if (high <= low) return OceanWaterSegment.empty;
    }
    return OceanWaterSegment(low, high);
  }
}

/// Hysteresis is for state transitions such as audio and particles. Optical
/// clipping uses the per-ray surface side, not this delayed state.
final class OceanSubmersion {
  final double enterBelow, exitAbove;
  bool _submerged;
  OceanSubmersion({
    this.enterBelow = -.02,
    this.exitAbove = .02,
    bool initiallySubmerged = false,
  }) : _submerged = initiallySubmerged {
    if (!enterBelow.isFinite ||
        !exitAbove.isFinite ||
        enterBelow >= exitAbove ||
        enterBelow > 0 ||
        exitAbove < 0) {
      throw ArgumentError(
        'Submersion thresholds must straddle zero in increasing order.',
      );
    }
  }
  bool get submerged => _submerged;
  bool update(double signedDistance) {
    if (!signedDistance.isFinite) {
      throw ArgumentError('Surface distance must be finite.');
    }
    if (_submerged && signedDistance >= exitAbove) _submerged = false;
    if (!_submerged && signedDistance <= enterBelow) _submerged = true;
    return _submerged;
  }
}
