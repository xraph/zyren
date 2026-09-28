import 'dart:typed_data';
import 'geometry.dart';
import 'morph_target.dart';
import 'vertex_attribute.dart';

/// CPU tangent preparation. Implementations return new geometry and split shared
/// vertices wherever face-corner tangents differ. No GPU device is required.
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

/// Payload and native scratch limits, excluding Dart copies and remapping maps.
/// Implementations must check [maxOutputBytes] before allocating output storage.
final class TangentGenerationLimits {
  final int maxOutputBytes;
  final int maxWorkingBytes;

  /// Maximum loop iterations in the native reference algorithm.
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
        !geometry.attributes.containsKey(
          uvSet == 0 ? VertexSemantic.uv0 : VertexSemantic.uv1,
        )) {
      throw const TangentGenerationException(
        TangentGenerationError.invalidData,
        'Tangent generation needs triangles and the selected UV attribute.',
      );
    }
  }
}

extension CornerTangents on GeometryData {
  /// Remaps face-corner XYZW tangents to indexed geometry without averaging.
  /// Copies every attribute, preserves its format and removes unused vertices.
  /// Existing tangents are replaced. Output uses the smallest index format.
  GeometryData withCornerTangents(
    Float32List tangents, {
    TangentGenerationLimits limits = const TangentGenerationLimits(),
  }) {
    limits.validate();
    if (topology != GeometryTopology.triangles ||
        tangents.length != indices.length * 4) {
      throw const TangentGenerationException(
        TangentGenerationError.invalidData,
        'Provide one XYZW tangent for each triangle corner.',
      );
    }
    final stride =
        attributes.entries
            .where((e) => e.key != VertexSemantic.tangent)
            .fold<int>(16, (sum, e) => sum + e.value.format.stride) +
        morphTargets.fold<int>(0, (n, t) => n + t.byteLength ~/ t.vertexCount);
    final remap = <(int, double, double, double, double), int>{};
    final sourceVertices = <int>[], sourceCorners = <int>[];
    final mapped = Uint32List(indices.length);
    for (var corner = 0; corner < indices.length; corner++) {
      final offset = corner * 4;
      final x = tangents[offset],
          y = tangents[offset + 1],
          z = tangents[offset + 2],
          w = tangents[offset + 3];
      final length2 = x * x + y * y + z * z;
      if (!length2.isFinite || (length2 - 1).abs() > 1e-4 || w.abs() != 1) {
        throw const TangentGenerationException(
          TangentGenerationError.invalidData,
          'Corner tangents must be finite unit vectors with handedness -1 or 1.',
        );
      }
      final key = (indices[corner], x, y, z, w);
      var vertex = remap[key];
      if (vertex == null) {
        vertex = sourceVertices.length;
        final count = vertex + 1;
        final bytes =
            count * stride + indices.length * (count <= 65536 ? 2 : 4);
        if (count > 1000000 || bytes > limits.maxOutputBytes) {
          throw const TangentGenerationException(
            TangentGenerationError.limitExceeded,
            'Tangent seam splitting exceeds the output geometry limit.',
          );
        }
        remap[key] = vertex;
        sourceVertices.add(indices[corner]);
        sourceCorners.add(offset);
      }
      mapped[corner] = vertex;
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
    Float32List? remapDeltas(Float32List? source) => source == null
        ? null
        : Float32List.fromList([
            for (final i in sourceVertices) ...source.sublist(i * 3, i * 3 + 3),
          ]);
    return GeometryData(
      morphTargets: [
        for (final target in morphTargets)
          MorphTarget(
            name: target.name,
            positions: remapDeltas(target.positions),
            normals: remapDeltas(target.normals),
            tangents: remapDeltas(target.tangents),
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
