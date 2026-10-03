import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'scalar_grid.dart';

enum ScientificSampleStatus { valid, missing, outside }

final class ScientificSample<T> {
  final ScientificSampleStatus status;
  final T? value;
  const ScientificSample(this.status, this.value);
}

/// Trilinear sampling in coordinates relative to the grid origin.
/// A zero-weight corner does not contribute to missing-data status.
ScientificSample<double> sampleScalar(ScalarGrid3D grid, Vec3 local) {
  if (!local.isFinite) throw ArgumentError('Sample position must be finite.');
  final q = [
    local.x / grid.spacing.x,
    local.y / grid.spacing.y,
    local.z / grid.spacing.z,
  ];
  final sizes = [grid.sizeX, grid.sizeY, grid.sizeZ];
  for (var i = 0; i < 3; i++) {
    if (q[i] < 0 || q[i] > sizes[i] - 1) {
      return const ScientificSample(ScientificSampleStatus.outside, null);
    }
  }
  final low = [for (final v in q) v.floor()];
  final high = [for (var i = 0; i < 3; i++) math.min(low[i] + 1, sizes[i] - 1)];
  final t = [for (var i = 0; i < 3; i++) q[i] - low[i]];
  var value = 0.0;
  for (var z = 0; z < 2; z++)
    for (var y = 0; y < 2; y++) {
      for (var x = 0; x < 2; x++) {
        final weight =
            (x == 0 ? 1 - t[0] : t[0]) *
            (y == 0 ? 1 - t[1] : t[1]) *
            (z == 0 ? 1 - t[2] : t[2]);
        if (weight == 0) continue;
        final v = grid.valueAt(
          x == 0 ? low[0] : high[0],
          y == 0 ? low[1] : high[1],
          z == 0 ? low[2] : high[2],
        );
        if (v == null) {
          return const ScientificSample(ScientificSampleStatus.missing, null);
        }
        value += v * weight;
      }
    }
  if (!value.isFinite) throw ArgumentError('Scalar interpolation overflow.');
  return ScientificSample(ScientificSampleStatus.valid, value);
}

bool compatibleGrids(ScalarGrid3D a, ScalarGrid3D b) =>
    a.sizeX == b.sizeX &&
    a.sizeY == b.sizeY &&
    a.sizeZ == b.sizeZ &&
    a.origin == b.origin &&
    a.spacing == b.spacing &&
    a.valueUnit == b.valueUnit &&
    a.coordinateUnit == b.coordinateUnit &&
    a.source.id == b.source.id &&
    a.source.kind == b.source.kind;
