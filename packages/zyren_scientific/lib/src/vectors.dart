import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'scalar_grid.dart';
import 'sampling.dart';
import 'transfer_function.dart';
import 'work.dart';

/// Orthonormal, right-handed component axes in the grid coordinate system.
final class VectorBasis {
  final Vec3 x, y, z;
  VectorBasis({required this.x, required this.y, required this.z}) {
    if ([x, y, z].any((v) => !v.isFinite || (v.length - 1).abs() > 1e-10) ||
        x.dot(y).abs() > 1e-10 ||
        x.dot(z).abs() > 1e-10 ||
        y.dot(z).abs() > 1e-10 ||
        x.cross(y).dot(z) < 1 - 1e-10) {
      throw ArgumentError('Vector basis must be orthonormal and right handed.');
    }
  }
  factory VectorBasis.cartesian() => VectorBasis(
    x: const Vec3(1, 0, 0),
    y: const Vec3(0, 1, 0),
    z: const Vec3(0, 0, 1),
  );
  Vec3 transform(Vec3 components) =>
      x * components.x + y * components.y + z * components.z;
}

/// Components share immutable grids, source identity, dimensions and units.
final class VectorGrid3D {
  final ScalarGrid3D x, y, z;
  final VectorBasis basis;
  VectorGrid3D({
    required this.x,
    required this.y,
    required this.z,
    required this.basis,
  }) {
    if (!compatibleGrids(x, y) || !compatibleGrids(x, z)) {
      throw ArgumentError('Vector component grids must match.');
    }
  }
  ScientificSample<Vec3> sample(Vec3 local) {
    final a = sampleScalar(x, local),
        b = sampleScalar(y, local),
        c = sampleScalar(z, local);
    for (final sample in [a, b, c]) {
      if (sample.status != ScientificSampleStatus.valid) {
        return ScientificSample(sample.status, null);
      }
    }
    final v = basis.transform(Vec3(a.value!, b.value!, c.value!));
    if (!v.length.isFinite) throw ArgumentError('Vector magnitude overflow.');
    return ScientificSample(ScientificSampleStatus.valid, v);
  }
}

/// Native line segments with one source sample ID per segment.
final class ScientificLines {
  final Vec3 origin;
  final ScientificSource source;
  final ScientificUnit coordinateUnit, valueUnit;
  final GeometryData? geometry;
  final List<int> sourceSamples;
  final double maxCoordinateError;
  ScientificLines._(
    this.origin,
    this.source,
    this.coordinateUnit,
    this.valueUnit,
    this.geometry,
    List<int> ids,
    this.maxCoordinateError,
  ) : sourceSamples = List.unmodifiable(ids);
  Mesh? createMesh({double width = 2}) => geometry == null
      ? null
      : (Mesh(
          BufferGeometry.fromData(geometry!),
          LineMaterial(width: width, vertexColors: true),
          name: '${source.kind.name}: ${source.description}',
        )..position = origin);
}

/// [lengthScale] is coordinate length per vector unit. Sampling order is XYZ.
Future<ScientificLines> buildVectorGlyphs({
  required VectorGrid3D field,
  required ScalarTransferFunction transfer,
  required double lengthScale,
  required double coordinateTolerance,
  int stride = 1,
  int maxGlyphs = 20000,
  ScientificBudget? budget,
  ScientificCancellation? cancellation,
}) async {
  if (!lengthScale.isFinite ||
      lengthScale <= 0 ||
      stride < 1 ||
      maxGlyphs < 1 ||
      maxGlyphs > 20000 ||
      transfer.unit != field.x.valueUnit) {
    throw ArgumentError('Invalid glyph settings or units.');
  }
  final g = field.x, limits = budget ?? ScientificBudget();
  final count =
      ((g.sizeX + stride - 1) ~/ stride) *
      ((g.sizeY + stride - 1) ~/ stride) *
      ((g.sizeZ + stride - 1) ~/ stride);
  if (count > maxGlyphs || count * 252 > limits.maxGeometryBytes) {
    throw ArgumentError('Glyph budget exceeded.');
  }
  final builder = _LineBuilder(g, coordinateTolerance, limits);
  var ordinal = 0;
  for (var z = 0; z < g.sizeZ; z += stride)
    for (var y = 0; y < g.sizeY; y += stride) {
      for (var x = 0; x < g.sizeX; x += stride) {
        if (ordinal++ % 256 == 0) await scientificYield(cancellation);
        final p = Vec3(x * g.spacing.x, y * g.spacing.y, z * g.spacing.z);
        final v = field.sample(p).value;
        if (v == null || v.length == 0) continue;
        final end = p + v * lengthScale, direction = v.normalized();
        final side = direction
            .cross(
              direction.z.abs() < .9
                  ? const Vec3(0, 0, 1)
                  : const Vec3(0, 1, 0),
            )
            .normalized();
        final length = v.length * lengthScale;
        final color = transfer.map(v.length)!;
        final id = x + g.sizeX * (y + g.sizeY * z);
        builder.segment(p, end, color, id);
        builder.segment(
          end,
          end - direction * (length * .25) + side * (length * .1),
          color,
          id,
        );
        builder.segment(
          end,
          end - direction * (length * .25) - side * (length * .1),
          color,
          id,
        );
      }
    }
  cancellation?.check();
  return builder.finish();
}

enum StreamlineTermination {
  length,
  domain,
  missing,
  stagnation,
  tolerance,
  workLimit,
}

final class StreamlineOptions {
  final double initialStep, minStep, maxStep, maxLength, tolerance, stagnation;
  final int maxSteps, maxPoints;
  final bool reverse;
  StreamlineOptions({
    this.initialStep = .05,
    this.minStep = 1e-5,
    this.maxStep = .1,
    this.maxLength = 10,
    this.tolerance = 1e-5,
    this.stagnation = 1e-12,
    this.maxSteps = 20000,
    this.maxPoints = 20000,
    this.reverse = false,
  }) {
    if ([
          initialStep,
          minStep,
          maxStep,
          maxLength,
          tolerance,
        ].any((v) => !v.isFinite || v <= 0) ||
        !stagnation.isFinite ||
        stagnation < 0 ||
        minStep > initialStep ||
        initialStep > maxStep ||
        maxSteps < 1 ||
        maxSteps > 100000 ||
        maxPoints < 2 ||
        maxPoints > 100000) {
      throw ArgumentError('Invalid streamline limits.');
    }
  }
}

final class Streamline {
  final VectorGrid3D field;
  final List<Vec3> points;
  final StreamlineTermination termination;
  final double length, maxLocalError;
  final int attempts;
  Streamline._(
    this.field,
    List<Vec3> points,
    this.termination,
    this.length,
    this.maxLocalError,
    this.attempts,
  ) : points = List.unmodifiable(points);
  ScientificLines geometry({
    required ScalarTransferFunction transfer,
    required double coordinateTolerance,
    ScientificBudget? budget,
  }) {
    if (transfer.unit != field.x.valueUnit) {
      throw ArgumentError('Vector magnitude units must match.');
    }
    final b = _LineBuilder(
      field.x,
      coordinateTolerance,
      budget ?? ScientificBudget(),
    );
    for (var i = 1; i < points.length; i++) {
      final magnitude = field.sample(points[i - 1]).value!.length;
      b.segment(points[i - 1], points[i], transfer.map(magnitude)!, i - 1);
    }
    return b.finish();
  }
}

/// Integrates a steady field by arc length with adaptive RK4 step doubling.
/// Positions and error tolerance use the grid's local coordinate length unit.
Future<Streamline> integrateStreamline({
  required VectorGrid3D field,
  required Vec3 seed,
  StreamlineOptions? options,
  ScientificCancellation? cancellation,
}) async {
  final o = options ?? StreamlineOptions();
  if (!seed.isFinite) throw ArgumentError('Seed must be finite.');
  final points = <Vec3>[seed];
  var length = 0.0, step = o.initialStep, maxError = 0.0, attempts = 0;
  StreamlineTermination? failure;
  Vec3? direction(Vec3 p) {
    final s = field.sample(p);
    if (s.status != ScientificSampleStatus.valid) {
      failure = s.status == ScientificSampleStatus.outside
          ? StreamlineTermination.domain
          : StreamlineTermination.missing;
      return null;
    }
    final v = s.value!;
    if (v.length <= o.stagnation) {
      failure = StreamlineTermination.stagnation;
      return null;
    }
    return v.normalized() * (o.reverse ? -1 : 1);
  }

  Vec3? rk4(Vec3 p, double h) {
    final a = direction(p);
    if (a == null) return null;
    final b = direction(p + a * (h * .5));
    if (b == null) return null;
    final c = direction(p + b * (h * .5));
    if (c == null) return null;
    final d = direction(p + c * h);
    if (d == null) return null;
    return p + (a + b * 2 + c * 2 + d) * (h / 6);
  }

  Streamline result(StreamlineTermination termination) =>
      Streamline._(field, points, termination, length, maxError, attempts);
  while (attempts < o.maxSteps && points.length < o.maxPoints) {
    if (attempts++ % 64 == 0) await scientificYield(cancellation);
    if (length >= o.maxLength) return result(StreamlineTermination.length);
    final remaining = o.maxLength - length;
    final h = math.min(step, remaining);
    failure = null;
    if (direction(points.last) == null) return result(failure!);
    final coarse = rk4(points.last, h), half = rk4(points.last, h * .5);
    final fine = half == null ? null : rk4(half, h * .5);
    if (coarse == null || fine == null || direction(fine) == null) {
      if (h <= o.minStep) {
        return result(failure ?? StreamlineTermination.domain);
      }
      step = math.max(o.minStep, h * .5);
      continue;
    }
    final error = coarse.distanceTo(fine);
    if (error > o.tolerance) {
      if (h <= o.minStep) return result(StreamlineTermination.tolerance);
      step = math.max(o.minStep, h * .5);
      continue;
    }
    if (fine == points.last) return result(StreamlineTermination.stagnation);
    points.add(fine);
    length += h;
    maxError = math.max(maxError, error);
    if (error < o.tolerance / 32) step = math.min(o.maxStep, h * 2);
    if (remaining == h) return result(StreamlineTermination.length);
  }
  cancellation?.check();
  return result(StreamlineTermination.workLimit);
}

final class _LineBuilder {
  final ScalarGrid3D grid;
  final double tolerance;
  final ScientificBudget budget;
  final positions = <double>[], colors = <double>[], ids = <int>[];
  double error = 0;
  _LineBuilder(this.grid, this.tolerance, this.budget) {
    if (!tolerance.isFinite || tolerance < 0) {
      throw ArgumentError('Invalid coordinate tolerance.');
    }
  }
  void segment(Vec3 a, Vec3 b, Color3 color, int id) {
    // Position, normal, color, index and source ID per expanded endpoint.
    if ((ids.length + 1) * 84 > budget.maxGeometryBytes ||
        ids.length >= 250000) {
      throw ArgumentError('Line geometry budget exceeded.');
    }
    final quantized = Float32List.fromList([...a.storage, ...b.storage]);
    final exact = [...a.storage, ...b.storage];
    for (var i = 0; i < 6; i++) {
      final e = (quantized[i] - exact[i]).abs();
      if (!quantized[i].isFinite || e > tolerance) {
        throw ArgumentError('Line exceeds coordinate tolerance.');
      }
      error = math.max(error, e);
    }
    if (Vec3.array(quantized) == Vec3.array(quantized, 3)) {
      throw ArgumentError('Float32 conversion collapses a line.');
    }
    positions.addAll(quantized);
    colors.addAll([...color.toList(), ...color.toList()]);
    ids.add(id);
  }

  ScientificLines finish() {
    VertexAttribute attr(List<double> v) => VertexAttribute(
      Float32List.fromList(v),
      format: VertexFormat.float32x3,
    );
    final data = ids.isEmpty
        ? null
        : GeometryData(
            attributes: {
              VertexSemantic.position: attr(positions),
              VertexSemantic.color: attr(colors),
              VertexSemantic.normal: attr([
                for (var i = 0; i < ids.length * 2; i++) ...[0, 0, 1],
              ]),
            },
            indices: List.generate(ids.length * 2, (i) => i),
            topology: GeometryTopology.lineSegments,
          );
    return ScientificLines._(
      grid.origin,
      grid.source,
      grid.coordinateUnit,
      grid.valueUnit,
      data,
      ids,
      error,
    );
  }
}
