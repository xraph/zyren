import 'dart:typed_data';
import 'geometry.dart';
import 'morph_target.dart';
import 'vertex_attribute.dart';

/// CPU tangent preparation. Implementations return new geometry and split shared
/// vertices wherever face-corner tangents differ in the base or any morph pose.
/// Replaces base tangents and every target's tangent deltas. No GPU is required.
abstract interface class TangentGenerator {
  Future<GeometryData> generate(
    GeometryData geometry, {
    int uvSet = 0,
    TangentGenerationLimits limits = const TangentGenerationLimits(),
  });
}

enum TangentGenerationError { invalidData, limitExceeded, busy, internal }

final class TangentGenerationException implements Exception {
  final TangentGenerationError code;
  final String message;
  const TangentGenerationException(this.code, this.message);
  @override
  String toString() => 'TangentGenerationException(${code.name}): $message';
}

/// Payload and native preparation limits, excluding input/output geometry copies
/// and remapping data structures.
/// Implementations must check [maxOutputBytes] before allocating output storage.
final class TangentGenerationLimits {
  final int maxOutputBytes;
  final int maxWorkingBytes;

  /// Total reference-loop budget, divided across the base and changed targets.
  final int maxIterations;
  const TangentGenerationLimits({
    this.maxOutputBytes = 128 * 1024 * 1024,
    this.maxWorkingBytes = 128 * 1024 * 1024,
    this.maxIterations = 100000000,
  });
  void validate() {
    RangeError.checkValueInInterval(
      maxOutputBytes,
      1,
      128 * 1024 * 1024,
      'maxOutputBytes',
    );
    RangeError.checkValueInInterval(
      maxWorkingBytes,
      1,
      128 * 1024 * 1024,
      'maxWorkingBytes',
    );
    RangeError.checkValueInInterval(
      maxIterations,
      1,
      100000000,
      'maxIterations',
    );
  }

  void validateInput(GeometryData geometry, {int uvSet = 0}) {
    validate();
    RangeError.checkValueInInterval(uvSet, 0, 1, 'uvSet');
    if (geometry.topology != GeometryTopology.triangles ||
        !geometry.attributes.containsKey(VertexSemantic.normal) ||
        !geometry.attributes.containsKey(
          uvSet == 0 ? VertexSemantic.uv0 : VertexSemantic.uv1,
        )) {
      throw const TangentGenerationException(
        TangentGenerationError.invalidData,
        'Tangent generation needs triangles, normals and the selected UV attribute.',
      );
    }
  }
}

extension CornerTangents on GeometryData {
  /// Remaps face-corner XYZW tangents to indexed geometry without averaging.
  /// Copies every attribute, preserves its format and removes unused vertices.
  /// Existing tangents are replaced. Output uses the smallest index format.
  /// Optional [morphTangents] contains absolute XYZW corner tangents for every
  /// target. Seams from all poses are retained and XYZ deltas replace authored
  /// target tangents. Target handedness is validated but cannot be morphed.
  GeometryData withCornerTangents(
    Float32List tangents, {
    List<Float32List>? morphTangents,
    TangentGenerationLimits limits = const TangentGenerationLimits(),
  }) {
    limits.validate();
    if (topology != GeometryTopology.triangles ||
        tangents.length != indices.length * 4 ||
        (morphTangents != null &&
            (morphTangents.length != morphTargets.length ||
                morphTangents.any((t) => t.length != tangents.length)))) {
      throw const TangentGenerationException(
        TangentGenerationError.invalidData,
        'Provide one XYZW tangent for each triangle corner.',
      );
    }
    final stride =
        attributes.entries
            .where((e) => e.key != VertexSemantic.tangent)
            .fold<int>(16, (sum, e) => sum + e.value.format.stride) +
        morphTargets.fold<int>(
          0,
          (n, t) =>
              n +
              (t.positions == null ? 0 : 12) +
              (t.normals == null ? 0 : 12) +
              (morphTangents != null || t.tangents != null ? 12 : 0),
        );
    void checkCount(int count) {
      final bytes = count * stride + indices.length * (count <= 65536 ? 2 : 4);
      if (count > 1000000 || bytes > limits.maxOutputBytes) {
        throw const TangentGenerationException(
          TangentGenerationError.limitExceeded,
          'Tangent seam splitting exceeds the output geometry limit.',
        );
      }
    }

    checkCount(1);
    var sourceVertices = <int>[], sourceCorners = <int>[];
    final mapped = Uint32List(indices.length);
    // Refine groups one pose at a time. A target can split a group, never merge
    // corners that disagree in the base or in a previously processed target.
    final streams = [tangents, ...?morphTangents];
    for (var pose = 0; pose < streams.length; pose++) {
      final stream = streams[pose];
      if (pose > 0 && identical(stream, tangents)) continue;
      final remap = <(int, double, double, double, double), int>{};
      sourceVertices = <int>[];
      sourceCorners = <int>[];
      for (var corner = 0; corner < indices.length; corner++) {
        final offset = corner * 4;
        final x = stream[offset],
            y = stream[offset + 1],
            z = stream[offset + 2],
            w = stream[offset + 3];
        final length2 = x * x + y * y + z * z;
        if (!length2.isFinite || (length2 - 1).abs() > 1e-4 || w.abs() != 1) {
          throw const TangentGenerationException(
            TangentGenerationError.invalidData,
            'Corner tangents must be finite unit vectors with handedness -1 or 1.',
          );
        }
        final key = (
          pose == 0 ? indices[corner] : mapped[corner],
          x,
          y,
          z,
          pose == 0 ? w : 0.0,
        );
        var vertex = remap[key];
        if (vertex == null) {
          vertex = sourceVertices.length;
          checkCount(vertex + 1);
          remap[key] = vertex;
          sourceVertices.add(indices[corner]);
          sourceCorners.add(offset);
        }
        mapped[corner] = vertex;
      }
    }
    final result = <VertexSemantic, VertexAttribute>{};
    for (final entry in attributes.entries) {
      if (entry.key == VertexSemantic.tangent) continue;
      final attribute = entry.value, size = attribute.format.stride;
      final input = attribute.data.buffer.asUint8List(
        attribute.data.offsetInBytes,
        attribute.data.lengthInBytes,
      );
      final bytes = Uint8List(sourceVertices.length * size);
      for (var i = 0; i < sourceVertices.length; i++) {
        bytes.setRange(
          i * size,
          (i + 1) * size,
          input,
          sourceVertices[i] * size,
        );
      }
      final TypedData data = switch (attribute.format) {
        VertexFormat.uint16x4 => bytes.buffer.asUint16List(),
        VertexFormat.uint32x4 => bytes.buffer.asUint32List(),
        VertexFormat.unorm8x4 => bytes,
        _ => bytes.buffer.asFloat32List(),
      };
      result[entry.key] = VertexAttribute(data, format: attribute.format);
    }
    final values = Float32List(sourceVertices.length * 4);
    for (var i = 0; i < sourceCorners.length; i++) {
      values.setRange(i * 4, i * 4 + 4, tangents, sourceCorners[i]);
    }
    result[VertexSemantic.tangent] = VertexAttribute(
      values,
      format: VertexFormat.float32x4,
    );
    Float32List? remapDeltas(Float32List? source) {
      if (source == null) return null;
      final result = Float32List(sourceVertices.length * 3);
      for (var i = 0; i < sourceVertices.length; i++) {
        result.setRange(i * 3, i * 3 + 3, source, sourceVertices[i] * 3);
      }
      return result;
    }

    Float32List targetDeltas(Float32List target) {
      final result = Float32List(sourceVertices.length * 3);
      for (var i = 0; i < sourceCorners.length; i++) {
        final at = sourceCorners[i];
        for (var c = 0; c < 3; c++) {
          result[i * 3 + c] = target[at + c] - tangents[at + c];
        }
      }
      return result;
    }

    return GeometryData(
      morphTargets: [
        for (var i = 0; i < morphTargets.length; i++)
          MorphTarget(
            name: morphTargets[i].name,
            positions: remapDeltas(morphTargets[i].positions),
            normals: remapDeltas(morphTargets[i].normals),
            tangents: morphTangents == null
                ? remapDeltas(morphTargets[i].tangents)
                : targetDeltas(morphTangents[i]),
          ),
      ],
      attributes: result,
      indices: mapped,
      indexFormat: sourceVertices.length <= 65536
          ? IndexFormat.uint16
          : IndexFormat.uint32,
    );
  }
}
