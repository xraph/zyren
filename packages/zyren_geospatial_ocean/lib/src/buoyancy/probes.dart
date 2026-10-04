import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'clipping.dart';
part 'hull.dart';

sealed class BuoyancyShape {
  const BuoyancyShape();
  double get volume;
  List<Vec3> get quadraturePoints;
  double get maximumCellDiameter;
}

void _sphere(double radius, double height) {
  if (!radius.isFinite || radius <= 0 || radius > 1e6 || !height.isFinite) {
    throw ArgumentError(
      'Sphere radius must be in (0, 1e6] metres and height finite.',
    );
  }
}

double submergedSphereVolume(double radius, double submergedHeight) {
  _sphere(radius, submergedHeight);
  final h = submergedHeight.clamp(0.0, 2 * radius);
  return math.pi * h * h * (radius - h / 3);
}

/// Signed offset from sphere centre along the outward water normal.
/// A dry sphere has no displaced centroid; its limiting offset is -radius.
double submergedSphereCentroidOffset(double radius, double submergedHeight) {
  _sphere(radius, submergedHeight);
  final h = submergedHeight.clamp(0.0, 2 * radius);
  return -3 * (2 * radius - h) * (2 * radius - h) / (4 * (3 * radius - h));
}

final class BuoyancyProbe {
  final Vec3 localCenter;
  final double radius;
  BuoyancyProbe(this.localCenter, this.radius) {
    _sphere(radius, 0);
    if (!localCenter.isFinite || localCenter.length > 1e9) {
      throw ArgumentError('Probe centre must be finite and within 1e9 metres.');
    }
  }
  double get volume => submergedSphereVolume(radius, 2 * radius);
}

/// Explicit approximate volume partition. Weights are effective displaced-volume
/// fractions, not a geometric union calculation for overlapping spheres.
final class BuoyancyProbePartition {
  final List<double> weights;
  final double declaredVolume;
  BuoyancyProbePartition({
    required List<double> weights,
    required this.declaredVolume,
  }) : weights = List.unmodifiable(weights) {
    if (!declaredVolume.isFinite ||
        declaredVolume <= 0 ||
        weights.any((w) => !w.isFinite || w <= 0 || w > 1)) {
      throw ArgumentError(
        'Partition weights must be in (0,1] with positive volume.',
      );
    }
  }
}

final class BuoyancyProbes extends BuoyancyShape {
  final List<BuoyancyProbe> probes;
  final BuoyancyProbePartition? partition;
  @override
  late final double volume;
  BuoyancyProbes(List<BuoyancyProbe> probes, {this.partition})
    : probes = List.unmodifiable(probes) {
    if (probes.isEmpty ||
        probes.length > 4096 ||
        (partition != null && partition!.weights.length != probes.length)) {
      throw ArgumentError(
        'Use 1..4096 probes and one partition weight per probe.',
      );
    }
    if (partition == null) {
      for (var i = 0; i < probes.length; i++) {
        for (var j = i + 1; j < probes.length; j++) {
          if (probes[i].localCenter.distanceTo(probes[j].localCenter) <
              probes[i].radius + probes[j].radius) {
            throw ArgumentError(
              'Overlapping probes require an explicit volume partition.',
            );
          }
        }
      }
    }
    final sum = List.generate(
      probes.length,
      (i) => probes[i].volume * weight(i),
    ).fold(0.0, (a, b) => a + b);
    if (partition != null &&
        (sum - partition!.declaredVolume).abs() > sum * 1e-10) {
      throw ArgumentError(
        'Weighted probe volume must equal the declared hull volume.',
      );
    }
    volume = sum;
  }
  double weight(int index) => partition?.weights[index] ?? 1;
  @override
  List<Vec3> get quadraturePoints =>
      List.unmodifiable(probes.map((p) => p.localCenter));
  @override
  double get maximumCellDiameter =>
      probes.map((p) => 2 * p.radius).reduce(math.max);
}
