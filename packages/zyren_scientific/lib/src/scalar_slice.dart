import 'dart:math' as math;
import 'dart:typed_data';

import 'package:zyren/zyren.dart';

import 'scalar_grid.dart';
import 'transfer_function.dart';

enum SliceAxis { x, y, z }

/// A CPU slice ready for an ordinary Zyren mesh. The source remains attached
/// so your application can show provenance next to the visualization.
final class ScalarSlice {
  final ScalarGrid3D grid;
  final ScalarTransferFunction transfer;
  final SliceAxis axis;
  final double index;
  final int width, height, renderedCells, omittedCells;
  final int belowRangeSamples, aboveRangeSamples;
  final Vec3 origin;
  final double maxCoordinateError;
  final GeometryData? geometry;
  final Float64List _values;
  final Uint8List _valid;

  ScalarSlice._({
    required this.grid,
    required this.transfer,
    required this.axis,
    required this.index,
    required this.width,
    required this.height,
    required this.renderedCells,
    required this.omittedCells,
    required this.belowRangeSamples,
    required this.aboveRangeSamples,
    required this.origin,
    required this.maxCoordinateError,
    required this.geometry,
    required Float64List values,
    required Uint8List valid,
  }) : _values = values,
       _valid = valid;

  /// Interpolate the plane at [index], in grid-index units along [axis].
  /// [coordinateTolerance] is an absolute error in the grid's coordinate unit.
  /// The preflight budget includes the full lattice, even with missing cells.
  factory ScalarSlice.build({
    required ScalarGrid3D grid,
    required ScalarTransferFunction transfer,
    required SliceAxis axis,
    required double index,
    required double coordinateTolerance,
    ScientificBudget? budget,
  }) {
    if (grid.valueUnit != transfer.unit) {
      throw ArgumentError(
        'Transfer and scalar field units must match exactly.',
      );
    }
    if (!coordinateTolerance.isFinite || coordinateTolerance < 0) {
      throw ArgumentError(
        'Coordinate tolerance must be finite and nonnegative.',
      );
    }
    final limits = budget ?? ScientificBudget();
    // Cyclic axes give positive-axis winding for every slice orientation.
    final (width, height, planes, du, dv, dn) = switch (axis) {
      SliceAxis.x => (
        grid.sizeY,
        grid.sizeZ,
        grid.sizeX,
        grid.spacing.y,
        grid.spacing.z,
        grid.spacing.x,
      ),
      SliceAxis.y => (
        grid.sizeZ,
        grid.sizeX,
        grid.sizeY,
        grid.spacing.z,
        grid.spacing.x,
        grid.spacing.y,
      ),
      SliceAxis.z => (
        grid.sizeX,
        grid.sizeY,
        grid.sizeZ,
        grid.spacing.x,
        grid.spacing.y,
        grid.spacing.z,
      ),
    };
    if (!index.isFinite || index < 0 || index > planes - 1) {
      throw RangeError('Slice index must be within the grid.');
    }
    if (width < 2 || height < 2) {
      throw ArgumentError(
        'A slice needs at least two samples on each plane axis.',
      );
    }
    final vertices = width * height;
    final cells = (width - 1) * (height - 1);
    // Three float32 triples (position, normal, color), six uint32 indices/cell.
    final upperGeometryBytes = vertices * 36 + cells * 24;
    if (vertices > limits.maxSamples ||
        cells > limits.maxSliceCells ||
        upperGeometryBytes > limits.maxGeometryBytes) {
      throw ArgumentError('Slice exceeds the sample, cell or geometry budget.');
    }
    final offset = dn * index;
    final origin =
        grid.origin +
        switch (axis) {
          SliceAxis.x => Vec3(offset, 0, 0),
          SliceAxis.y => Vec3(0, offset, 0),
          SliceAxis.z => Vec3(0, 0, offset),
        };
    if (!origin.isFinite) throw ArgumentError('Slice origin must be finite.');
    final positions = Float32List(vertices * 3);
    final normals = Float32List(vertices * 3);
    final colors = Float32List(vertices * 3);
    final indices = Uint32List(cells * 6);
    final values = Float64List(vertices);
    final valid = Uint8List(vertices);
    final low = index.floor();
    final t = index - low;
    double? sample(int u, int v, int plane) => switch (axis) {
      SliceAxis.x => grid.valueAt(plane, u, v),
      SliceAxis.y => grid.valueAt(v, plane, u),
      SliceAxis.z => grid.valueAt(u, v, plane),
    };
    var coordinateError = 0.0;
    var below = 0, above = 0;
    for (var v = 0; v < height; v++) {
      for (var u = 0; u < width; u++) {
        final vertex = v * width + u;
        final p = switch (axis) {
          SliceAxis.x => Vec3(0, u * du, v * dv),
          SliceAxis.y => Vec3(v * dv, 0, u * du),
          SliceAxis.z => Vec3(u * du, v * dv, 0),
        };
        final coordinates = p.storage;
        for (var component = 0; component < 3; component++) {
          final i = vertex * 3 + component;
          positions[i] = coordinates[component];
          final error = (positions[i] - coordinates[component]).abs();
          if (!positions[i].isFinite || error > coordinateTolerance) {
            throw ArgumentError(
              'Local coordinate exceeds float32 error tolerance.',
            );
          }
          coordinateError = math.max(coordinateError, error);
        }
        final uComponent = (axis.index + 1) % 3;
        final vComponent = (axis.index + 2) % 3;
        if ((u > 0 &&
                positions[vertex * 3 + uComponent] <=
                    positions[(vertex - 1) * 3 + uComponent]) ||
            (v > 0 &&
                positions[vertex * 3 + vComponent] <=
                    positions[(vertex - width) * 3 + vComponent])) {
          throw ArgumentError(
            'Float32 conversion collapses adjacent grid points.',
          );
        }
        normals[vertex * 3 + axis.index] = 1;
        final a = sample(u, v, low);
        // Exact planes do not depend on an unused neighbor's validity.
        final b = t == 0 ? a : sample(u, v, low + 1);
        if (a == null || b == null) continue;
        final value = t == 0 ? a : a * (1 - t) + b * t;
        if (!value.isFinite) {
          throw ArgumentError('Slice interpolation overflowed.');
        }
        values[vertex] = value;
        valid[vertex] = 1;
        if (value < transfer.minimum) below++;
        if (value > transfer.maximum) above++;
        final color = transfer.map(value)!;
        colors.setRange(vertex * 3, vertex * 3 + 3, color.toList());
      }
    }
    var indexCount = 0;
    for (var v = 0; v < height - 1; v++) {
      for (var u = 0; u < width - 1; u++) {
        final a = v * width + u, b = a + 1, c = a + width, d = c + 1;
        if (valid[a] == 0 || valid[b] == 0 || valid[c] == 0 || valid[d] == 0) {
          continue;
        }
        indices.setRange(indexCount, indexCount + 6, [a, b, d, a, d, c]);
        indexCount += 6;
      }
    }
    final geometry = indexCount == 0
        ? null
        : GeometryData(
            attributes: {
              VertexSemantic.position: VertexAttribute(
                positions,
                format: VertexFormat.float32x3,
              ),
              VertexSemantic.normal: VertexAttribute(
                normals,
                format: VertexFormat.float32x3,
              ),
              VertexSemantic.color: VertexAttribute(
                colors,
                format: VertexFormat.float32x3,
              ),
            },
            indices: Uint32List.sublistView(indices, 0, indexCount),
          );
    return ScalarSlice._(
      grid: grid,
      transfer: transfer,
      axis: axis,
      index: index,
      width: width,
      height: height,
      renderedCells: indexCount ~/ 6,
      omittedCells: cells - indexCount ~/ 6,
      belowRangeSamples: below,
      aboveRangeSamples: above,
      origin: origin,
      maxCoordinateError: coordinateError,
      geometry: geometry,
      values: values,
      valid: valid,
    );
  }

  bool get isEmpty => geometry == null;
  int get geometryBytes => geometry?.byteLength ?? 0;
  int get samplePayloadBytes => _values.lengthInBytes + _valid.lengthInBytes;

  double? valueAt(int u, int v) {
    RangeError.checkValidIndex(u, _values, 'u', width);
    RangeError.checkValidIndex(v, _values, 'v', height);
    final at = v * width + u;
    return _valid[at] == 0 ? null : _values[at];
  }

  /// No mesh is created for an empty result. Scene/backend lifecycle owns the
  /// ordinary geometry upload. This result owns no separate GPU allocations.
  Mesh? createMesh() {
    final data = geometry;
    if (data == null) return null;
    return Mesh(
      BufferGeometry.fromData(data),
      UnlitMaterial(vertexColors: true),
      name: '${grid.name} [${grid.source.kind.name}] ${axis.name}=$index',
    )..position = origin;
  }
}
