import 'dart:math' as math;
import 'dart:typed_data';

import 'package:zyren/zyren.dart';

import 'scalar_grid.dart';
import 'transfer_function.dart';
import 'work.dart';

enum ScalarAssociation { vertex, cell }

/// Triangle data with source-cell identity and local float32 error accounting.
final class ScientificSurface {
  final ScientificSource source;
  final ScientificUnit valueUnit, coordinateUnit;
  final Vec3 origin;
  final GeometryData? geometry;
  final List<int> sourceCells;
  final int omittedCells;
  final double maxCoordinateError;

  ScientificSurface._(
    this.source,
    this.valueUnit,
    this.coordinateUnit,
    this.origin,
    this.geometry,
    List<int> cells,
    this.omittedCells,
    this.maxCoordinateError,
  ) : sourceCells = List.unmodifiable(cells);

  Mesh? createMesh() => geometry == null
      ? null
      : (Mesh(
          BufferGeometry.fromData(geometry!),
          UnlitMaterial(vertexColors: true),
          name: '${source.kind.name}: ${source.description}',
        )..position = origin);

  /// Positions are local to [origin]. Cell values use flat triangle colors.
  /// Missing values omit affected triangles. Invalid connectivity is rejected.
  static Future<ScientificSurface> build({
    required List<Vec3> positions,
    required List<int> indices,
    required List<double?> values,
    required ScalarAssociation association,
    required Vec3 origin,
    required ScientificSource source,
    required ScientificUnit coordinateUnit,
    required ScalarTransferFunction transfer,
    required double coordinateTolerance,
    List<int>? sourceCells,
    ScientificBudget? budget,
    ScientificCancellation? cancellation,
  }) async {
    final limits = budget ?? ScientificBudget();
    final cells = indices.length ~/ 3;
    if (!origin.isFinite ||
        coordinateUnit.quantity != 'length' ||
        indices.length % 3 != 0 ||
        cells > limits.maxSliceCells ||
        positions.length > limits.maxSamples ||
        values.length !=
            (association == ScalarAssociation.vertex
                ? positions.length
                : cells) ||
        (sourceCells != null &&
            (sourceCells.length != cells || sourceCells.any((i) => i < 0)))) {
      throw ArgumentError('Invalid surface dimensions, identity or budget.');
    }
    // Freeze caller input before yielding to asynchronous cancellation.
    final points = List<Vec3>.of(positions), triangles = List<int>.of(indices);
    final scalars = List<double?>.of(values);
    final identities = sourceCells == null
        ? List.generate(cells, (i) => i)
        : List<int>.of(sourceCells);
    if (points.any((p) => !p.isFinite) ||
        scalars.any((v) => v != null && !v.isFinite) ||
        triangles.any((i) => i < 0 || i >= points.length)) {
      throw ArgumentError(
        'Invalid surface coordinates, scalars or connectivity.',
      );
    }
    final builder = SurfaceBuilder(limits, coordinateTolerance);
    final shared = <int, int>{};
    var omitted = 0;
    for (var cell = 0; cell < cells; cell++) {
      if (cell % 256 == 0) await scientificYield(cancellation);
      final corners = triangles.sublist(cell * 3, cell * 3 + 3);
      final samples = [
        for (final i in corners)
          scalars[association == ScalarAssociation.vertex ? i : cell],
      ];
      final normal = (points[corners[1]] - points[corners[0]]).cross(
        points[corners[2]] - points[corners[0]],
      );
      if (!normal.isFinite || !normal.length.isFinite || normal.length == 0) {
        throw ArgumentError(
          'Degenerate or overflowing source triangle at $cell.',
        );
      }
      if (samples.any((v) => v == null)) {
        omitted++;
        continue;
      }
      final vertices = <int>[];
      for (var j = 0; j < 3; j++) {
        final key = association == ScalarAssociation.vertex
            ? corners[j]
            : cell * 3 + j;
        vertices.add(
          shared.putIfAbsent(
            key,
            () => builder.vertex(points[corners[j]], transfer.map(samples[j])!),
          ),
        );
      }
      builder.triangle(vertices[0], vertices[1], vertices[2], identities[cell]);
    }
    cancellation?.check();
    return builder.finish(
      source,
      transfer.unit,
      coordinateUnit,
      origin,
      omitted,
    );
  }
}

/// Six tetrahedra share the 000-to-111 body diagonal in every regular cell.
/// Exact threshold samples belong to the low side; missing cells leave holes.
Future<ScientificSurface> extractIsosurface({
  required ScalarGrid3D grid,
  required double threshold,
  required ScalarTransferFunction transfer,
  required double coordinateTolerance,
  ScientificBudget? budget,
  ScientificCancellation? cancellation,
}) async {
  final limits = budget ?? ScientificBudget();
  final nx = grid.sizeX - 1, ny = grid.sizeY - 1, nz = grid.sizeZ - 1;
  if (!threshold.isFinite ||
      transfer.unit != grid.valueUnit ||
      nx < 1 ||
      ny < 1 ||
      nz < 1 ||
      nx * ny * nz > limits.maxSliceCells ||
      grid.sampleCount > limits.maxSamples) {
    throw ArgumentError(
      'Isosurfaces need a finite threshold and a bounded 3D grid with matching units.',
    );
  }
  final builder = SurfaceBuilder(limits, coordinateTolerance);
  final edgeVertices = <(int, int), int>{};
  const offsets = [
    (0, 0, 0),
    (1, 0, 0),
    (1, 1, 0),
    (0, 1, 0),
    (0, 0, 1),
    (1, 0, 1),
    (1, 1, 1),
    (0, 1, 1),
  ];
  const tetrahedra = [
    [0, 1, 2, 6],
    [0, 2, 3, 6],
    [0, 3, 7, 6],
    [0, 7, 4, 6],
    [0, 4, 5, 6],
    [0, 5, 1, 6],
  ];
  final color = transfer.map(threshold)!;
  var omitted = 0;
  for (var z = 0; z < nz; z++) {
    for (var y = 0; y < ny; y++) {
      for (var x = 0; x < nx; x++) {
        final cell = x + nx * (y + ny * z);
        if (cell % 256 == 0) await scientificYield(cancellation);
        final samples = [
          for (final o in offsets) grid.valueAt(x + o.$1, y + o.$2, z + o.$3),
        ];
        if (samples.any((v) => v == null)) {
          omitted++;
          continue;
        }
        final ids = [
          for (final o in offsets)
            x + o.$1 + grid.sizeX * (y + o.$2 + grid.sizeY * (z + o.$3)),
        ];
        final points = [
          for (final o in offsets)
            Vec3(
              (x + o.$1) * grid.spacing.x,
              (y + o.$2) * grid.spacing.y,
              (z + o.$3) * grid.spacing.z,
            ),
        ];
        int edge(int a, int b) {
          if (samples[a] == threshold) b = a;
          if (samples[b] == threshold) a = b;
          if (ids[a] > ids[b]) {
            final temp = a;
            a = b;
            b = temp;
          }
          return edgeVertices.putIfAbsent((ids[a], ids[b]), () {
            // Scale before subtraction so finite extreme values cannot overflow.
            final scale = math.max(
              threshold.abs(),
              math.max(samples[a]!.abs(), samples[b]!.abs()),
            );
            final t = a == b
                ? 0.0
                : (threshold / scale - samples[a]! / scale) /
                      (samples[b]! / scale - samples[a]! / scale);
            return builder.vertex(points[a] * (1 - t) + points[b] * t, color);
          });
        }

        for (final tet in tetrahedra) {
          final low = tet.where((i) => samples[i]! <= threshold).toList();
          final high = tet.where((i) => samples[i]! > threshold).toList();
          if (low.isEmpty || high.isEmpty) continue;
          final direction = points[high.first] - points[low.first];
          void triangle(int a, int b, int c) {
            if (a == b || a == c || b == c) return;
            final normal = (builder.points[b] - builder.points[a]).cross(
              builder.points[c] - builder.points[a],
            );
            if (normal.dot(direction) < 0) {
              final temp = b;
              b = c;
              c = temp;
            }
            builder.triangle(a, b, c, cell);
          }

          if (low.length == 1 || high.length == 1) {
            final alone = low.length == 1 ? low.single : high.single;
            final others = low.length == 1 ? high : low;
            triangle(
              edge(alone, others[0]),
              edge(alone, others[1]),
              edge(alone, others[2]),
            );
          } else {
            final a = edge(low[0], high[0]), b = edge(low[0], high[1]);
            final c = edge(low[1], high[0]), d = edge(low[1], high[1]);
            triangle(a, b, d);
            triangle(a, d, c);
          }
        }
      }
    }
  }
  cancellation?.check();
  return builder.finish(
    grid.source,
    grid.valueUnit,
    grid.coordinateUnit,
    grid.origin,
    omitted,
  );
}

/// Internal bounded builder. Payload includes the source-cell table.
final class SurfaceBuilder {
  final ScientificBudget limits;
  final double tolerance;
  final points = <Vec3>[], normals = <Vec3>[];
  final colors = <double>[], indices = <int>[], cells = <int>[];
  double error = 0;
  SurfaceBuilder(this.limits, this.tolerance) {
    if (!tolerance.isFinite || tolerance < 0) {
      throw ArgumentError('Invalid coordinate tolerance.');
    }
  }
  void _budget(int vertices, int triangles) {
    if (vertices > limits.maxSamples ||
        triangles > 1000000 ||
        vertices * 36 + triangles * 16 > limits.maxGeometryBytes) {
      throw ArgumentError('Surface geometry budget exceeded.');
    }
  }

  int vertex(Vec3 p, Color3 color) {
    _budget(points.length + 1, cells.length);
    final quantized = Float32List.fromList(p.storage);
    for (var i = 0; i < 3; i++) {
      final e = (quantized[i] - p.storage[i]).abs();
      if (!quantized[i].isFinite || e > tolerance) {
        throw ArgumentError('Surface exceeds coordinate tolerance.');
      }
      error = math.max(error, e);
    }
    points.add(Vec3.array(quantized));
    normals.add(Vec3.zero);
    colors.addAll(color.toList());
    return points.length - 1;
  }

  void triangle(int a, int b, int c, int cell) {
    _budget(points.length, cells.length + 1);
    final n = (points[b] - points[a]).cross(points[c] - points[a]);
    if (!n.length.isFinite || n.length == 0) {
      throw ArgumentError('Float32 conversion collapses a triangle.');
    }
    for (final i in [a, b, c]) {
      normals[i] = normals[i] + n;
    }
    indices.addAll([a, b, c]);
    cells.add(cell);
  }

  ScientificSurface finish(
    ScientificSource source,
    ScientificUnit unit,
    ScientificUnit coordinateUnit,
    Vec3 origin,
    int omitted,
  ) {
    VertexAttribute attribute(List<double> v) => VertexAttribute(
      Float32List.fromList(v),
      format: VertexFormat.float32x3,
    );
    final data = indices.isEmpty
        ? null
        : GeometryData(
            attributes: {
              VertexSemantic.position: attribute([
                for (final p in points) ...p.storage,
              ]),
              VertexSemantic.normal: attribute([
                for (final n in normals)
                  ...(n.length == 0 ? Vec3.zero : n.normalized()).storage,
              ]),
              VertexSemantic.color: attribute(colors),
            },
            indices: indices,
          );
    return ScientificSurface._(
      source,
      unit,
      coordinateUnit,
      origin,
      data,
      cells,
      omitted,
      error,
    );
  }
}
