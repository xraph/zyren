import 'dart:typed_data';
import 'vertex_attribute.dart';

/// A fixed vertex count and semantic-to-format mapping shared by every revision.
final class VertexLayout {
  final int vertexCount;
  final Map<VertexSemantic, VertexFormat> formats;
  VertexLayout(Map<VertexSemantic, VertexAttribute> attributes)
    : vertexCount = attributes[VertexSemantic.position]?.count ?? 0,
      formats = Map.unmodifiable(
        attributes.map((key, value) => MapEntry(key, value.format)),
      ) {
    if (vertexCount == 0 ||
        vertexCount > 1000000 ||
        !attributes.containsKey(VertexSemantic.normal)) {
      throw ArgumentError(
        'Geometry needs positions and normals for 1 to 1000000 vertices.',
      );
    }
    for (final entry in attributes.entries) {
      if (entry.value.count != vertexCount) {
        throw ArgumentError('Vertex attribute counts must match.');
      }
      validate(entry.key, entry.value);
    }
  }
  static void validate(VertexSemantic semantic, VertexAttribute attribute) {
    final allowed = switch (semantic) {
      VertexSemantic.position ||
      VertexSemantic.normal => {VertexFormat.float32x3},
      VertexSemantic.uv0 || VertexSemantic.uv1 => {VertexFormat.float32x2},
      VertexSemantic.color => {
        VertexFormat.float32x3,
        VertexFormat.float32x4,
        VertexFormat.unorm8x4,
      },
      VertexSemantic.joints => {VertexFormat.uint16x4, VertexFormat.uint32x4},
      _ => {VertexFormat.float32x4},
    };
    if (!allowed.contains(attribute.format)) {
      throw ArgumentError('Unsupported format for ${semantic.name}.');
    }
    if (attribute.data case Float32List values) {
      for (var i = 0; i < values.length; i += attribute.format.components) {
        if (semantic == VertexSemantic.normal ||
            semantic == VertexSemantic.tangent) {
          if (values[i] * values[i] +
                  values[i + 1] * values[i + 1] +
                  values[i + 2] * values[i + 2] <
              1e-12) {
            throw ArgumentError('Normals and tangents must be nonzero.');
          }
        }
        if (semantic == VertexSemantic.tangent && values[i + 3].abs() != 1) {
          throw ArgumentError('Tangent handedness must be -1 or 1.');
        }
        if (semantic == VertexSemantic.color ||
            semantic == VertexSemantic.weights) {
          var sum = 0.0;
          for (var j = 0; j < attribute.format.components; j++) {
            final value = values[i + j];
            if (value < 0 || value > 1) {
              throw ArgumentError('Colors and weights must be in [0, 1].');
            }
            sum += value;
          }
          if (semantic == VertexSemantic.weights && (sum - 1).abs() > 1e-4) {
            throw ArgumentError('Vertex weights must sum to one.');
          }
        }
      }
    }
  }
}
