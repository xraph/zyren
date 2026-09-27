part of 'geometry.dart';

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
  final int id, logicalId, revision;
  final VertexLayout layout;
  final Map<VertexSemantic, VertexAttribute> attributes;
  final List<int> indices;
  final List<GeometryChange> history;
  GeometrySnapshot._({
    required this.id,
    required this.logicalId,
    required this.revision,
    required this.layout,
    required Map<VertexSemantic, VertexAttribute> attributes,
    required this.indices,
    required List<GeometryChange> history,
  }) : attributes = Map.unmodifiable(attributes),
       history = List.unmodifiable(history);
  List<double> get positions =>
      attributes[VertexSemantic.position]!.data as Float32List;
  List<double> get normals =>
      attributes[VertexSemantic.normal]!.data as Float32List;
  List<double>? get uv0 => attributes[VertexSemantic.uv0]?.data as Float32List?;
  List<double>? get uv1 => attributes[VertexSemantic.uv1]?.data as Float32List?;

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
    'positions': [
      for (var i = 0; i < positions.length; i += 3) positions.sublist(i, i + 3),
    ],
    'normals': [
      for (var i = 0; i < normals.length; i += 3) normals.sublist(i, i + 3),
    ],
    'indices': indices,
  };
}
