import 'dart:typed_data';
import '../math/vec3.dart';
import 'geometry.dart';
import 'morph_target.dart';
import 'subdivision.dart';
import 'vertex_attribute.dart';

/// CPU topology operations. Inputs stay unchanged; results own new identities.
abstract final class GeometryUtils {
  /// Refines triangle geometry while retaining independent UV and color seams.
  /// See [subdivideGeometry] for supported topology and worker-isolate use.
  static BufferGeometry subdivide(
    BufferGeometry source, {
    int levels = 1,
    SubdivisionMode mode = SubdivisionMode.loop,
    bool weldPositions = true,
    SubdivisionLimits limits = const SubdivisionLimits(),
    IndexFormat indexFormat = IndexFormat.uint32,
  }) => BufferGeometry.fromData(
    subdivideGeometry(
      GeometryData(
        attributes: source.attributes,
        indices: source.indices,
        topology: source.topology,
        morphTargets: source.morphTargets,
        indexFormat: source.indexFormat,
      ),
      levels: levels,
      mode: mode,
      weldPositions: weldPositions,
      limits: limits,
      indexFormat: indexFormat,
    ),
  );

  /// Expands every indexed corner, including colors, skin data and morph deltas.
  static BufferGeometry toNonIndexed(
    BufferGeometry source, {
    IndexFormat indexFormat = IndexFormat.uint32,
  }) {
    final corners = source.indices;
    _budget(corners.length, corners.length, indexFormat);
    final stride =
        source.attributes.values.fold<int>(0, (s, a) => s + a.format.stride) +
        source.morphTargets.fold<int>(
          0,
          (s, t) => s + t.byteLength ~/ t.vertexCount,
        );
    if (corners.length * (stride + indexFormat.bytesPerIndex) >
        64 * 1024 * 1024) {
      throw ArgumentError('Expanded geometry exceeds 64 MiB.');
    }
    List<double>? deltas(List<double>? data) => data == null
        ? null
        : [for (final i in corners) ...data.sublist(i * 3, i * 3 + 3)];
    return BufferGeometry.fromAttributes(
      attributes: {
        for (final entry in source.attributes.entries)
          entry.key: _remap(entry.value, corners),
      },
      indices: List.generate(corners.length, (i) => i),
      indexFormat: indexFormat,
      topology: source.topology,
      morphTargets: [
        for (final target in source.morphTargets)
          MorphTarget(
            name: target.name,
            positions: deltas(target.positions),
            normals: deltas(target.normals),
            tangents: deltas(target.tangents),
          ),
      ],
    );
  }

  /// Merges equal layouts in their existing local coordinates. Skin and morph
  /// binding remapping belongs to the asset/animation layer and is rejected here.
  static BufferGeometry merge(
    List<BufferGeometry> sources, {
    IndexFormat indexFormat = IndexFormat.uint32,
  }) {
    if (sources.isEmpty) {
      throw ArgumentError('Merge needs at least one geometry.');
    }
    final first = sources.first;
    var count = 0, indexCount = 0;
    for (final source in sources) {
      if (source.topology != first.topology ||
          source.topology == GeometryTopology.lineStrip ||
          source.attributes.length != first.attributes.length ||
          source.morphTargets.isNotEmpty ||
          source.attributes.containsKey(VertexSemantic.joints) ||
          first.attributes.entries.any(
            (e) => source.attributes[e.key]?.format != e.value.format,
          )) {
        throw ArgumentError(
          'Merge needs matching layouts and topology without skin, morph or line-strip bindings.',
        );
      }
      count += source.vertexCount;
      indexCount += source.indices.length;
      _budget(count, indexCount, indexFormat);
    }
    final stride = first.attributes.values.fold<int>(
      0,
      (s, a) => s + a.format.stride,
    );
    if (count * stride + indexCount * indexFormat.bytesPerIndex >
        64 * 1024 * 1024) {
      throw ArgumentError('Merged geometry exceeds 64 MiB.');
    }
    final attributes = <VertexSemantic, VertexAttribute>{};
    for (final entry in first.attributes.entries) {
      final bytes = Uint8List(count * entry.value.format.stride);
      var offset = 0;
      for (final source in sources) {
        final data = source.attributes[entry.key]!.data;
        bytes.setRange(
          offset,
          offset + data.lengthInBytes,
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        offset += data.lengthInBytes;
      }
      attributes[entry.key] = _attribute(bytes, entry.value.format);
    }
    final indices = <int>[];
    var offset = 0;
    for (final source in sources) {
      indices.addAll(source.indices.map((i) => i + offset));
      offset += source.vertexCount;
    }
    return BufferGeometry.fromAttributes(
      attributes: attributes,
      indices: indices,
      indexFormat: indexFormat,
      topology: first.topology,
    );
  }

  /// Area-weighted vertex normals. Unreferenced or cancelling vertices retain
  /// their prior normals. Tangents must be regenerated after changing normals.
  /// Deformed geometry requires regenerated deltas first.
  static BufferGeometry computeVertexNormals(BufferGeometry source) {
    if (source.topology != GeometryTopology.triangles ||
        source.morphTargets.isNotEmpty) {
      throw ArgumentError(
        'Normal generation needs triangle geometry without morph targets.',
      );
    }
    final normals = List<Vec3>.filled(source.vertexCount, Vec3.zero);
    for (var i = 0; i < source.indices.length; i += 3) {
      final a = source.indices[i],
          b = source.indices[i + 1],
          c = source.indices[i + 2];
      final p = Vec3.array(source.positions, a * 3),
          q = Vec3.array(source.positions, b * 3),
          r = Vec3.array(source.positions, c * 3);
      final normal = (q - p).cross(r - p);
      normals[a] = normals[a] + normal;
      normals[b] = normals[b] + normal;
      normals[c] = normals[c] + normal;
    }
    return BufferGeometry.fromAttributes(
      attributes: {
        for (final entry in source.attributes.entries)
          if (entry.key != VertexSemantic.tangent) entry.key: entry.value,
        VertexSemantic.normal: VertexAttribute(
          Float32List.fromList([
            for (var i = 0; i < normals.length; i++)
              ...(normals[i].length2 > 1e-30
                      ? normals[i].normalized()
                      : Vec3.array(source.normals, i * 3).normalized())
                  .storage,
          ]),
          format: VertexFormat.float32x3,
        ),
      },
      indices: source.indices,
      indexFormat: source.indexFormat,
    );
  }

  static void _budget(int vertices, int indices, IndexFormat format) {
    if (vertices > (format == IndexFormat.uint16 ? 65536 : 1000000) ||
        indices > 3000000) {
      throw ArgumentError('Topology operation exceeds the geometry budget.');
    }
  }
}

VertexAttribute _remap(VertexAttribute attribute, List<int> indices) {
  final stride = attribute.format.stride;
  final source = attribute.data.buffer.asUint8List(
    attribute.data.offsetInBytes,
    attribute.data.lengthInBytes,
  );
  final result = Uint8List(indices.length * stride);
  for (var i = 0; i < indices.length; i++) {
    result.setRange(i * stride, (i + 1) * stride, source, indices[i] * stride);
  }
  return _attribute(result, attribute.format);
}

VertexAttribute _attribute(Uint8List bytes, VertexFormat format) =>
    VertexAttribute(switch (format) {
      VertexFormat.float32x2 ||
      VertexFormat.float32x3 ||
      VertexFormat.float32x4 => bytes.buffer.asFloat32List(),
      VertexFormat.uint16x4 => bytes.buffer.asUint16List(),
      VertexFormat.uint32x4 => bytes.buffer.asUint32List(),
      VertexFormat.unorm8x4 => bytes,
    }, format: format);
