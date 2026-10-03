import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

void main() {
  test(
    'damped inverse recovers a choppy material coordinate with an analytic Jacobian',
    () async {
      const expectedX = 1.7, expectedY = -.8;
      OceanHorizontalField field(double x, double y) => OceanHorizontalField(
        x + .4 * math.sin(x) + .1 * math.cos(y),
        y + .2 * math.sin(y),
        1 + .4 * math.cos(x),
        -.1 * math.sin(y),
        0,
        1 + .2 * math.cos(y),
      );
      final target = field(expectedX, expectedY);
      final result = await invertOceanHorizontal(
        targetX: target.x,
        targetY: target.y,
        initialX: target.x,
        initialY: target.y,
        evaluate: (x, y) async => field(x, y),
        maxIterations: 12,
        tolerance: 1e-9,
        maxStep: 2,
      );
      expect(result.failure, isNull);
      expect(result.x, closeTo(expectedX, 1e-8));
      expect(result.y, closeTo(expectedY, 1e-8));
      expect(result.residual, lessThanOrEqualTo(1e-9));
      expect(result.minimumSingularValue, greaterThan(.5));
    },
  );
  test(
    'folds, singular matrices and exhausted convergence never yield valid coordinates',
    () async {
      for (final (field, reason) in [
        (OceanHorizontalField(0, 0, -1, 0, 0, 1), OceanQueryFailure.folded),
        (
          OceanHorizontalField(0, 0, 1e-12, 0, 0, 1),
          OceanQueryFailure.singular,
        ),
        (
          OceanHorizontalField(0, 0, 1, 0, 0, 1),
          OceanQueryFailure.nonConvergent,
        ),
      ]) {
        final result = await invertOceanHorizontal(
          targetX: 1,
          targetY: 1,
          initialX: 0,
          initialY: 0,
          evaluate: (x, y) async => field,
          maxIterations: 4,
          tolerance: 1e-6,
          maxStep: 1,
        );
        expect(result.failure, reason);
        expect(result.x, isNull);
        expect(result.y, isNull);
      }
    },
  );
  test(
    'cancellation fences an accepted evaluation and travel remains bounded',
    () async {
      final cancellation = LoadCancellationSource();
      final cancelled = await invertOceanHorizontal(
        targetX: 1,
        targetY: 1,
        initialX: 0,
        initialY: 0,
        evaluate: (x, y) async {
          cancellation.cancel();
          return OceanHorizontalField(x, y, 1, 0, 0, 1);
        },
        maxIterations: 4,
        tolerance: 1e-6,
        maxStep: 1,
        cancellation: cancellation,
      );
      expect(cancelled.failure, OceanQueryFailure.cancelled);
      expect(cancelled.evaluations, 1);
      final bounded = await invertOceanHorizontal(
        targetX: 100,
        targetY: 0,
        initialX: 0,
        initialY: 0,
        evaluate: (x, y) async => OceanHorizontalField(x, y, 1, 0, 0, 1),
        maxIterations: 4,
        tolerance: 1e-6,
        maxStep: 1,
        maxDistance: 2,
      );
      expect(bounded.failure, OceanQueryFailure.nonConvergent);
      expect(bounded.evaluations, lessThanOrEqualTo(1 + 4 * 8));
      final exact = await invertOceanHorizontal(
        targetX: 1,
        targetY: 0,
        initialX: 0,
        initialY: 0,
        evaluate: (x, y) async => OceanHorizontalField(x, y, 1, 0, 0, 1),
        maxIterations: 1,
        tolerance: 1e-6,
        maxStep: 1,
      );
      expect(exact.failure, isNull);
      expect(exact.evaluations, 2);
    },
  );
}
