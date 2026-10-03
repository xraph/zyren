import 'dart:math' as math;
import 'package:zyren/zyren.dart';

enum OceanQueryFailure {
  outsideCoverage,
  sourceUnavailable,
  sourceChanged,
  timelineChanged,
  stale,
  frameChanged,
  cancelled,
  closed,
  busy,
  workBudget,
  allocation,
  unsupportedState,
  folded,
  singular,
  nonConvergent,
  accuracy,
  failed,
}

/// Eulerian horizontal position and its derivative with respect to material x/y.
final class OceanHorizontalField {
  final double x, y, xx, xy, yx, yy;
  OceanHorizontalField(this.x, this.y, this.xx, this.xy, this.yx, this.yy) {
    if (![x, y, xx, xy, yx, yy].every((v) => v.isFinite && v.abs() <= 1e12)) {
      throw ArgumentError(
        'Horizontal fields require finite bounded coordinates and derivatives.',
      );
    }
  }
  ({double determinant, double minimumSingularValue}) get condition {
    final scale = [xx.abs(), xy.abs(), yx.abs(), yy.abs()].reduce(math.max);
    if (scale == 0) return (determinant: 0, minimumSingularValue: 0);
    final a = xx / scale,
        b = xy / scale,
        c = yx / scale,
        d = yy / scale,
        det = a * d - b * c;
    final sum = a * a + b * b + c * c + d * d;
    final largest = math.sqrt(
      (sum + math.sqrt(math.max(0, sum * sum - 4 * det * det))) / 2,
    );
    return (
      determinant: det * scale * scale,
      minimumSingularValue: scale * det.abs() / largest,
    );
  }
}

/// A local solve result. Successful convergence alone does not certify uniqueness.
final class OceanHorizontalInverse {
  final double? x, y;
  final double residual, minimumSingularValue;
  final int evaluations;
  final OceanQueryFailure? failure;
  const OceanHorizontalInverse._(
    this.x,
    this.y,
    this.residual,
    this.minimumSingularValue,
    this.evaluations,
    this.failure,
  );
}

/// Damped Newton with bounded travel and eight backtracking trials per iteration.
Future<OceanHorizontalInverse> invertOceanHorizontal({
  required double targetX,
  required double targetY,
  required double initialX,
  required double initialY,
  required Future<OceanHorizontalField> Function(double x, double y) evaluate,
  required int maxIterations,
  required double tolerance,
  required double maxStep,
  double maxDistance = 1e6,
  double minimumSingularValue = 1e-6,
  LoadCancellation? cancellation,
}) async {
  if (![
        targetX,
        targetY,
        initialX,
        initialY,
      ].every((v) => v.isFinite && v.abs() <= 1e12) ||
      maxIterations < 1 ||
      maxIterations > 32 ||
      !tolerance.isFinite ||
      tolerance <= 0 ||
      !maxStep.isFinite ||
      maxStep <= 0 ||
      !maxDistance.isFinite ||
      maxDistance <= 0 ||
      maxDistance > 1e9 ||
      !minimumSingularValue.isFinite ||
      minimumSingularValue <= 0 ||
      minimumSingularValue > 1) {
    throw ArgumentError('Invalid bounded ocean inversion policy.');
  }
  var x = initialX,
      y = initialY,
      evaluations = 0,
      residual = double.infinity,
      smallest = 0.0;
  OceanHorizontalInverse fail(OceanQueryFailure reason) =>
      OceanHorizontalInverse._(
        null,
        null,
        residual,
        smallest,
        evaluations,
        reason,
      );
  if (cancellation?.isCancelled ?? false) {
    return fail(OceanQueryFailure.cancelled);
  }
  var value = await evaluate(x, y);
  evaluations++;
  for (var iteration = 0; iteration <= maxIterations; iteration++) {
    if (cancellation?.isCancelled ?? false) {
      return fail(OceanQueryFailure.cancelled);
    }
    final rx = value.x - targetX, ry = value.y - targetY;
    residual = math.sqrt(rx * rx + ry * ry);
    final condition = value.condition;
    smallest = condition.minimumSingularValue;
    if (condition.determinant < 0) return fail(OceanQueryFailure.folded);
    if (smallest < minimumSingularValue) {
      return fail(OceanQueryFailure.singular);
    }
    if (residual <= tolerance) {
      return OceanHorizontalInverse._(
        x,
        y,
        residual,
        smallest,
        evaluations,
        null,
      );
    }
    if (iteration == maxIterations) {
      return fail(OceanQueryFailure.nonConvergent);
    }
    final dx = (value.yy * rx - value.xy * ry) / condition.determinant,
        dy = (value.xx * ry - value.yx * rx) / condition.determinant;
    final length = math.sqrt(dx * dx + dy * dy);
    var fraction = math.min(1.0, maxStep / length), accepted = false;
    for (var trial = 0; trial < 8; trial++) {
      if (cancellation?.isCancelled ?? false) {
        return fail(OceanQueryFailure.cancelled);
      }
      final nx = x - dx * fraction, ny = y - dy * fraction;
      if (math.sqrt(
            (nx - initialX) * (nx - initialX) +
                (ny - initialY) * (ny - initialY),
          ) <=
          maxDistance) {
        final candidate = await evaluate(nx, ny);
        evaluations++;
        if (cancellation?.isCancelled ?? false) {
          return fail(OceanQueryFailure.cancelled);
        }
        final cx = candidate.x - targetX, cy = candidate.y - targetY;
        if (candidate.condition.determinant > 0 &&
            candidate.condition.minimumSingularValue >= minimumSingularValue &&
            math.sqrt(cx * cx + cy * cy) < residual * (1 - 1e-4 * fraction)) {
          x = nx;
          y = ny;
          value = candidate;
          accepted = true;
          break;
        }
      }
      fraction *= .5;
    }
    if (!accepted) return fail(OceanQueryFailure.nonConvergent);
  }
  return fail(OceanQueryFailure.nonConvergent);
}
