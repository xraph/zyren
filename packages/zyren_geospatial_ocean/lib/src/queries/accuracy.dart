import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../surface/cube_patch.dart';
import 'canonical.dart';
import 'field_error.dart';

/// Conservative material-map bounds over a fixed query tangent disk.
/// They bound the numerical surface model, not its agreement with real water.
final class OceanSurfaceBounds {
  final Ellipsoid ellipsoid;
  late final double radius,
      chartDerivative,
      chartHessian,
      displacementGradient,
      displacementHessian,
      horizontalContraction,
      heightLipschitz,
      surfaceHessian,
      normalCurvature,
      weightGradient,
      velocityGradient,
      geodesyError;
  late final bool admissible;
  OceanSurfaceBounds({
    required this.ellipsoid,
    required double meanLevel,
    required List<OceanCanonicalEnvelope> charts,
  }) {
    validateOceanEllipsoid(ellipsoid);
    if (!meanLevel.isFinite || charts.length != 6) {
      throw ArgumentError('All six fixed chart envelopes are required.');
    }
    var h0 = 0.0,
        h1 = 0.0,
        h2 = 0.0,
        d0 = 0.0,
        d1 = 0.0,
        d2 = 0.0,
        v0 = 0.0,
        v1 = 0.0;
    for (final e in charts) {
      if ([
        e.height,
        e.slope,
        e.heightHessian,
        e.displacement,
        e.displacementGradient,
        e.displacementHessian,
        e.velocity,
        e.velocityGradient,
      ].any((v) => !v.isFinite || v < 0)) {
        throw ArgumentError('Invalid canonical envelope.');
      }
      h0 = math.max(h0, e.height);
      h1 = math.max(h1, e.slope);
      h2 = math.max(h2, e.heightHessian);
      d0 = math.max(d0, e.displacement);
      d1 = math.max(d1, e.displacementGradient);
      d2 = math.max(d2, e.displacementHessian);
      v0 = math.max(v0, e.velocity);
      v1 = math.max(v1, e.velocityGradient);
    }
    final small = ellipsoid.minimumRadius,
        kappa = ellipsoid.maximumRadius / (small * small),
        w1 = 1024 * kappa,
        w2 = 1048576 * kappa * kappa,
        h = meanLevel.abs() + h0;
    normalCurvature = kappa;
    weightGradient = w1;
    radius = math.max(
      math.max(1e-6, math.min(1.0, small * 1e-4)),
      4 * (h + d0),
    );
    geodesyError = math.max(
      1e-10,
      64 * 2.220446049250313e-16 * ellipsoid.maximumRadius,
    );
    final hg = h1 + w1 * h0,
        hh = h2 + 2 * w1 * h1 + w2 * h0,
        dg = d1 + w1 * d0,
        dh = d2 + 2 * w1 * d1 + w2 * d0;
    displacementGradient = hg + kappa * h + dg + 2 * kappa * d0;
    displacementHessian =
        hh +
        2 * kappa * hg +
        8 * kappa * kappa * h +
        dh +
        4 * kappa * dg +
        24 * kappa * kappa * d0;
    chartHessian = radius < small
        ? 4 * kappa / math.pow(1 - radius / small, 2)
        : double.infinity;
    chartDerivative = 1 + chartHessian * radius;
    final tilt = math.min(1.0, kappa * chartDerivative * radius),
        horizontal = kappa * h + tilt * hg + dg + 2 * kappa * d0;
    horizontalContraction =
        chartHessian * radius + chartDerivative * horizontal;
    heightLipschitz =
        chartHessian * radius + chartDerivative * displacementGradient;
    surfaceHessian =
        chartHessian * (1 + displacementGradient) +
        displacementHessian * chartDerivative * chartDerivative;
    velocityGradient = v1 + (w1 + 2 * kappa) * v0;
    admissible =
        radius <= .01 * small &&
        horizontalContraction.isFinite &&
        horizontalContraction < .8 &&
        [
          heightLipschitz,
          surfaceHessian,
          velocityGradient,
        ].every((v) => v.isFinite);
  }

  /// A posterior error disk inside the admitted tangent domain, or null if unproved.
  OceanSurfaceAccuracy? assess({
    required double residual,
    required double materialDistance,
    required Vec3 eastDerivative,
    required Vec3 northDerivative,
    required List<OceanFieldError> fieldErrors,
  }) {
    if (!admissible ||
        !residual.isFinite ||
        residual < 0 ||
        !materialDistance.isFinite ||
        materialDistance < 0 ||
        fieldErrors.isEmpty ||
        fieldErrors.length > 3 ||
        !eastDerivative.isFinite ||
        !northDerivative.isFinite) {
      return null;
    }
    var h = 0.0, d = 0.0, hg = 0.0, dg = 0.0, velocity = 0.0;
    for (final e in fieldErrors) {
      if ([
        e.height,
        e.displacement,
        e.slope,
        e.displacementGradient,
        e.velocity,
      ].any((v) => !v.isFinite || v < 0)) {
        return null;
      }
      h = math.max(h, e.height);
      d = math.max(d, math.sqrt2 * e.displacement);
      hg = math.max(hg, math.sqrt2 * e.slope);
      dg = math.max(dg, 2 * e.displacementGradient);
      velocity = math.max(velocity, math.sqrt(3) * e.velocity);
    }
    final positionError = h + d + geodesyError * (1 + displacementGradient);
    final disk = (residual + positionError) / (1 - horizontalContraction);
    if (!disk.isFinite || materialDistance + disk > radius) return null;
    final gradientError =
        hg + dg + weightGradient * (h + d) + normalCurvature * (h + 2 * d);
    final derivativeError =
        gradientError * chartDerivative +
        surfaceHessian * (disk + geodesyError) +
        1e-12;
    final cross = eastDerivative.cross(northDerivative).length;
    final crossError =
        derivativeError * (eastDerivative.length + northDerivative.length) +
        derivativeError * derivativeError;
    if (!cross.isFinite || cross <= crossError || cross == 0) return null;
    return OceanSurfaceAccuracy(
      positionError + heightLipschitz * disk,
      math.asin((crossError / cross).clamp(0, 1)),
      velocity + velocityGradient * (chartDerivative * disk + geodesyError),
      disk,
    );
  }
}

final class OceanSurfaceAccuracy {
  final double heightErrorMetres,
      normalErrorRadians,
      velocityErrorMetresPerSecond,
      rootRadiusMetres;
  const OceanSurfaceAccuracy(
    this.heightErrorMetres,
    this.normalErrorRadians,
    this.velocityErrorMetresPerSecond,
    this.rootRadiusMetres,
  );
}
