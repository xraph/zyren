import 'dart:typed_data';

enum VertexSemantic {
  position,
  normal,
  uv0,
  uv1,
  tangent,
  color,
  joints,
  weights,
}

enum VertexFormat {
  float32x2,
  float32x3,
  float32x4,
  uint16x4,
  uint32x4,
  unorm8x4;

  int get components => switch (this) {
    float32x2 => 2,
    float32x3 => 3,
    _ => 4,
  };
  int get stride =>
      components *
      switch (this) {
        uint16x4 => 2,
        unorm8x4 => 1,
        _ => 4,
      };
}

/// Owned, immutable vertex values. Normalized bytes are intended for colors.
final class VertexAttribute {
  final VertexFormat format;
  final TypedData data;
  VertexAttribute(TypedData values, {required this.format})
    : data = _copy(values, format) {
    if (data.lengthInBytes % format.stride != 0) {
      throw ArgumentError('Attribute values must contain complete vertices.');
    }
    if (data is Float32List && (data as Float32List).any((v) => !v.isFinite)) {
      throw ArgumentError('Vertex components must fit finite float32 storage.');
    }
  }
  int get count => data.lengthInBytes ~/ format.stride;
  static TypedData _copy(TypedData data, VertexFormat format) => switch ((
    format,
    data,
  )) {
    (
      VertexFormat.float32x2 ||
          VertexFormat.float32x3 ||
          VertexFormat.float32x4,
      Float32List values,
    ) =>
      Float32List.fromList(values).asUnmodifiableView(),
    (VertexFormat.uint16x4, Uint16List values) => Uint16List.fromList(
      values,
    ).asUnmodifiableView(),
    (VertexFormat.uint32x4, Uint32List values) => Uint32List.fromList(
      values,
    ).asUnmodifiableView(),
    (VertexFormat.unorm8x4, Uint8List values) => Uint8List.fromList(
      values,
    ).asUnmodifiableView(),
    _ => throw ArgumentError('Typed values do not match the vertex format.'),
  };
}
