part of 'geometry.dart';

/// Immutable local bounds of one geometry revision, shared by its instances.
final class GeometryBounds {
  final Vec3 minimum, maximum;
  GeometryBounds._(this.minimum, this.maximum);
  factory GeometryBounds._capture(List<double> values) {
    var minX = values[0], minY = values[1], minZ = values[2];
    var maxX = minX, maxY = minY, maxZ = minZ;
    for (var i = 3; i < values.length; i += 3) {
      minX = math.min(minX, values[i]);
      maxX = math.max(maxX, values[i]);
      minY = math.min(minY, values[i + 1]);
      maxY = math.max(maxY, values[i + 1]);
      minZ = math.min(minZ, values[i + 2]);
      maxZ = math.max(maxZ, values[i + 2]);
    }
    return GeometryBounds._(Vec3(minX, minY, minZ), Vec3(maxX, maxY, maxZ));
  }
  List<Vec3> get corners => List.unmodifiable([
    for (final x in [minimum.x, maximum.x])
      for (final y in [minimum.y, maximum.y])
        for (final z in [minimum.z, maximum.z]) Vec3(x, y, z),
  ]);
}

final class GeometryRange {
  final VertexSemantic semantic;
  final int firstVertex, vertexCount;
  const GeometryRange(this.semantic, this.firstVertex, this.vertexCount);
}

final class GeometryChange {
  final int revision;
  final GeometryRange range;
  const GeometryChange(this.revision, this.range);
}

/// Immutable CPU data for one geometry revision. Transfer IDs identify versions.
final class GeometrySnapshot {
  late final GeometryBounds bounds = GeometryBounds._capture(positions);
  final int id, logicalId, revision;
  final VertexLayout layout;
  final Map<VertexSemantic, VertexAttribute> attributes;
  final List<int> indices;
  final IndexFormat indexFormat;
  final GeometryTopology topology;
  final List<GeometryChange> history;
  GeometrySnapshot._({
    required this.id,
    required this.logicalId,
    required this.revision,
    required this.layout,
    required Map<VertexSemantic, VertexAttribute> attributes,
    required this.indices,
    required this.indexFormat,
    required this.topology,
    required List<GeometryChange> history,
  }) : attributes = Map.unmodifiable(attributes),
       history = List.unmodifiable(history);
  List<double> get positions =>
      attributes[VertexSemantic.position]!.data as Float32List;
  List<double> get normals =>
      attributes[VertexSemantic.normal]!.data as Float32List;
  List<double>? get uv0 => attributes[VertexSemantic.uv0]?.data as Float32List?;
  List<double>? get uv1 => attributes[VertexSemantic.uv1]?.data as Float32List?;

  List<double>? get tangents =>
      attributes[VertexSemantic.tangent]?.data as Float32List?;

  /// Linear RGBA values, normalized and padded once per immutable revision.
  late final List<double>? colors = _colors();
  List<double>? _colors() {
    final attribute = attributes[VertexSemantic.color];
    if (attribute == null) return null;
    final values = attribute.data;
    if (values is Float32List && attribute.format == VertexFormat.float32x4) {
      return values;
    }
    final output = Float32List(layout.vertexCount * 4);
    final components = attribute.format.components;
    for (var i = 0; i < layout.vertexCount; i++) {
      for (var c = 0; c < 4; c++) {
        output[i * 4 + c] = c >= components
            ? 1
            : values is Uint8List
            ? values[i * components + c] / 255
            : (values as Float32List)[i * components + c];
      }
    }
    return output.asUnmodifiableView();
  }

  int get primitiveCount => switch (topology) {
    GeometryTopology.triangles => indices.length ~/ 3,
    GeometryTopology.lineSegments => indices.length ~/ 2,
    GeometryTopology.lineStrip => indices.length - 1,
    GeometryTopology.points => indices.length,
  };
  int get gpuByteLength => topology == GeometryTopology.triangles
      ? positions.length * 8 +
            indices.length * indexFormat.bytesPerIndex +
            (uv0 != null || uv1 != null ? layout.vertexCount * 16 : 0) +
            (tangents == null ? 0 : layout.vertexCount * 16) +
            (colors == null ? 0 : layout.vertexCount * 16)
      : primitiveCount * (colors == null ? 120 : 248);

  /// Null means the base is incompatible or older than the bounded journal.
  List<GeometryRange>? changesSince(GeometrySnapshot base) {
    if (logicalId != base.logicalId ||
        !identical(layout, base.layout) ||
        base.revision > revision) {
      return null;
    }
    if (base.revision == revision) return const [];
    if (history.isEmpty || history.first.revision > base.revision + 1) {
      return null;
    }
    final merged = <GeometryRange>[];
    for (final semantic in VertexSemantic.values) {
      final ranges = [
        for (final change in history)
          if (change.revision > base.revision &&
              change.range.semantic == semantic)
            change.range,
      ]..sort((a, b) => a.firstVertex.compareTo(b.firstVertex));
      for (final range in ranges) {
        if (merged.isNotEmpty &&
            merged.last.semantic == semantic &&
            range.firstVertex <=
                merged.last.firstVertex + merged.last.vertexCount) {
          final last = merged.removeLast();
          final end =
              (range.firstVertex + range.vertexCount) >
                  (last.firstVertex + last.vertexCount)
              ? range.firstVertex + range.vertexCount
              : last.firstVertex + last.vertexCount;
          merged.add(
            GeometryRange(semantic, last.firstVertex, end - last.firstVertex),
          );
        } else {
          merged.add(range);
        }
      }
    }
    return List.unmodifiable(merged);
  }

  Map<String, Object> toNative() => {
    'id': id,
    'topology': topology.index,
    'positions': [
      for (var i = 0; i < positions.length; i += 3) positions.sublist(i, i + 3),
    ],
    'normals': [
      for (var i = 0; i < normals.length; i += 3) normals.sublist(i, i + 3),
    ],
    if (tangents != null)
      'tangents': [
        for (var i = 0; i < tangents!.length; i += 4)
          tangents!.sublist(i, i + 4),
      ],
    if (colors != null)
      'colors': [
        for (var i = 0; i < colors!.length; i += 4) colors!.sublist(i, i + 4),
      ],
    'indices': indices,
    'index_format': indexFormat.name,
  };
}
