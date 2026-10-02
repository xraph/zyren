import 'dart:typed_data';
import '../math/vec3.dart';
import 'geometry.dart';
import 'vertex_attribute.dart';

enum SubdivisionMode {
  /// Smooths positions with Loop edge rules and the 3/16, 3/(8n) vertex weights.
  loop,

  /// Splits triangles at edge midpoints without moving the original surface.
  linear,
}

/// You can lower these bounds for interactive work. They bound output payload
/// and topology counts, not total Dart heap use during refinement.
final class SubdivisionLimits {
  final int maxTriangles, maxBytes;
  const SubdivisionLimits({
    this.maxTriangles = 100000,
    this.maxBytes = 64 * 1024 * 1024,
  });
}

/// Refines immutable triangle data on the calling isolate. Each level makes
/// four triangles per input triangle. The result expands corners to retain UV
/// and color seams, and omits tangents, which need regeneration.
///
/// Exact position welding joins separate face vertices by default. Use
/// [weldPositions] false when coincident positions belong to separate surfaces.
/// Loop mode recomputes smooth area-weighted normals; linear mode interpolates
/// the authored normals. Skin and morph bindings require a separate remap and
/// are rejected. Input must be an oriented manifold, possibly with boundaries.
/// Self-intersections between otherwise valid faces are not detected.
GeometryData subdivideGeometry(
  GeometryData source, {
  int levels = 1,
  SubdivisionMode mode = SubdivisionMode.loop,
  bool weldPositions = true,
  SubdivisionLimits limits = const SubdivisionLimits(),
  IndexFormat indexFormat = IndexFormat.uint32,
}) {
  if (levels < 0 ||
      levels > 6 ||
      limits.maxTriangles < 1 ||
      limits.maxTriangles > 250000 ||
      limits.maxBytes < 1 ||
      limits.maxBytes > 64 * 1024 * 1024) {
    throw ArgumentError(
      'Subdivision needs 0 to 6 levels and valid bounded limits.',
    );
  }
  if (source.topology != GeometryTopology.triangles ||
      source.morphTargets.isNotEmpty ||
      source.attributes.containsKey(VertexSemantic.joints)) {
    throw ArgumentError(
      'Subdivision needs triangles without skin or morph bindings.',
    );
  }
  if (source.layout.vertexCount > 100000) {
    throw ArgumentError('Subdivision accepts at most 100000 input vertices.');
  }
  var triangles = source.indices.length ~/ 3;
  for (var step = 0; step <= levels; step++) {
    if (triangles > limits.maxTriangles) {
      throw ArgumentError(
        'Subdivision exceeds maxTriangles (${limits.maxTriangles}).',
      );
    }
    if (step < levels) triangles *= 4;
  }
  final stride = source.attributes.entries.fold<int>(
    24,
    (n, entry) =>
        n +
        (entry.key == VertexSemantic.uv0 ||
                entry.key == VertexSemantic.uv1 ||
                entry.key == VertexSemantic.color
            ? entry.value.format.stride
            : 0),
  );
  if (triangles * 3 > (indexFormat == IndexFormat.uint16 ? 65536 : 750000) ||
      triangles * 3 * (stride + indexFormat.bytesPerIndex) > limits.maxBytes) {
    throw ArgumentError(
      'Subdivision exceeds the vertex range or maxBytes (${limits.maxBytes}).',
    );
  }

  final raw = source.attributes[VertexSemantic.position]!.data as Float32List;
  final positions = <Vec3>[];
  final welded = <Vec3, int>{};
  final vertexMap = Uint32List(source.layout.vertexCount);
  for (var i = 0; i < vertexMap.length; i++) {
    final p = Vec3.array(raw, i * 3);
    vertexMap[i] = weldPositions
        ? welded.putIfAbsent(p, () {
            positions.add(p);
            return positions.length - 1;
          })
        : positions.length;
    if (!weldPositions) positions.add(p);
  }
  var faces = Uint32List(source.indices.length);
  for (var i = 0; i < faces.length; i++) {
    faces[i] = vertexMap[source.indices[i]];
  }
  var channels = <VertexSemantic, Float64List>{};
  final formats = <VertexSemantic, VertexFormat>{};
  for (final entry in source.attributes.entries) {
    if (entry.key != VertexSemantic.uv0 &&
        entry.key != VertexSemantic.uv1 &&
        entry.key != VertexSemantic.color &&
        !(entry.key == VertexSemantic.normal &&
            mode == SubdivisionMode.linear)) {
      continue;
    }
    final count = entry.value.format.components;
    formats[entry.key] = entry.value.format;
    final values = entry.value.data;
    channels[entry.key] = Float64List.fromList([
      for (final i in source.indices)
        for (var c = 0; c < count; c++)
          values is Uint8List
              ? values[i * count + c].toDouble()
              : (values as Float32List)[i * count + c],
    ]);
  }
  var current = positions;
  for (var level = 0; level < levels; level++) {
    final topology = _Topology(current, faces);
    final refined = <Vec3>[
      for (var i = 0; i < current.length; i++)
        mode == SubdivisionMode.linear ? current[i] : topology.even(i),
    ];
    for (final edge in topology.edges.values) {
      edge.child = refined.length;
      refined.add(
        mode == SubdivisionMode.loop && edge.oppositeB != null
            ? (current[edge.a] + current[edge.b]) * .375 +
                  (current[edge.oppositeA] + current[edge.oppositeB!]) * .125
            : (current[edge.a] + current[edge.b]) * .5,
      );
    }
    final children = Uint32List(faces.length * 4);
    final nextChannels = {
      for (final entry in channels.entries)
        entry.key: Float64List(entry.value.length * 4),
    };
    for (var f = 0; f < faces.length; f += 3) {
      final a = faces[f], b = faces[f + 1], c = faces[f + 2];
      final ab = topology.edges[_key(a, b)]!.child;
      final bc = topology.edges[_key(b, c)]!.child;
      final ca = topology.edges[_key(c, a)]!.child;
      children.setRange(f * 4, f * 4 + 12, [
        a,
        ab,
        ca,
        ab,
        b,
        bc,
        ca,
        bc,
        c,
        ab,
        bc,
        ca,
      ]);
      for (final entry in channels.entries) {
        final n = formats[entry.key]!.components;
        final input = entry.value, output = nextChannels[entry.key]!;
        for (var component = 0; component < n; component++) {
          final x = input[f * n + component],
              y = input[(f + 1) * n + component],
              z = input[(f + 2) * n + component];
          final xy = (x + y) * .5, yz = (y + z) * .5, zx = (z + x) * .5;
          final values = [x, xy, zx, xy, y, yz, zx, yz, z, xy, yz, zx];
          for (var corner = 0; corner < 12; corner++) {
            output[(f * 4 + corner) * n + component] = values[corner];
          }
        }
      }
    }
    current = refined;
    faces = children;
    channels = nextChannels;
  }
  // Validate the final float32 surface, including precision collapse after
  // refinement. Topology and normals must describe the vertices sent to the GPU.
  final floatPositions = Float32List.fromList([
    for (final p in current) ...p.storage,
  ]);
  current = [
    for (var i = 0; i < current.length; i++) Vec3.array(floatPositions, i * 3),
  ];
  final finalTopology = _Topology(current, faces);
  final normalData = channels.remove(VertexSemantic.normal);
  final normalSums = mode == SubdivisionMode.loop
      ? finalTopology.normals()
      : null;
  final resultNormals = Float32List(faces.length * 3);
  for (var corner = 0; corner < faces.length; corner++) {
    final n = normalSums == null
        ? Vec3.array(normalData!, corner * 3)
        : normalSums[faces[corner]];
    if (!n.isFinite || n.length2 == 0) {
      throw ArgumentError('Subdivision produces an undefined vertex normal.');
    }
    final unit = n.normalized();
    resultNormals.setRange(corner * 3, corner * 3 + 3, unit.storage);
  }
  return GeometryData(
    attributes: {
      VertexSemantic.position: VertexAttribute(
        Float32List.fromList([for (final i in faces) ...current[i].storage]),
        format: VertexFormat.float32x3,
      ),
      VertexSemantic.normal: VertexAttribute(
        resultNormals,
        format: VertexFormat.float32x3,
      ),
      for (final entry in channels.entries)
        entry.key: VertexAttribute(
          formats[entry.key] == VertexFormat.unorm8x4
              ? Uint8List.fromList([for (final v in entry.value) v.round()])
              : Float32List.fromList(entry.value),
          format: formats[entry.key]!,
        ),
    },
    indices: List.generate(faces.length, (i) => i),
    indexFormat: indexFormat,
  );
}

(int, int) _key(int a, int b) => a < b ? (a, b) : (b, a);

final class _Edge {
  final int a, b, oppositeA, faceA;
  int? oppositeB, faceB;
  int child = -1;
  _Edge(this.a, this.b, this.oppositeA, this.faceA);
}

final class _Topology {
  final List<Vec3> positions;
  final Uint32List faces;
  final edges = <(int, int), _Edge>{};
  late final List<Set<int>> neighbors;
  late final List<List<int>> boundary;
  _Topology(this.positions, this.faces) {
    neighbors = List.generate(positions.length, (_) => <int>{});
    boundary = List.generate(positions.length, (_) => <int>[]);
    final incidents = List.generate(positions.length, (_) => <int>[]);
    final unique = <(int, int, int)>{};
    for (var f = 0; f < faces.length; f += 3) {
      final a = faces[f], b = faces[f + 1], c = faces[f + 2];
      final sorted = [a, b, c]..sort();
      if (a == b ||
          b == c ||
          c == a ||
          !unique.add((sorted[0], sorted[1], sorted[2]))) {
        throw ArgumentError(
          'Subdivision input has collapsed or duplicate triangles.',
        );
      }
      final p = positions[a], q = positions[b], r = positions[c];
      final cross = (q - p).cross(r - p);
      if (!p.isFinite ||
          !q.isFinite ||
          !r.isFinite ||
          !cross.isFinite ||
          cross.length2 == 0) {
        throw ArgumentError(
          'Subdivision input has a nonfinite or degenerate triangle.',
        );
      }
      for (var corner = 0; corner < 3; corner++) {
        final from = faces[f + corner],
            to = faces[f + (corner + 1) % 3],
            opposite = faces[f + (corner + 2) % 3];
        incidents[from].add(f);
        neighbors[from].add(to);
        neighbors[to].add(from);
        final key = _key(from, to);
        final edge = edges[key];
        if (edge == null) {
          edges[key] = _Edge(from, to, opposite, f);
        } else {
          if (edge.faceB != null || edge.a != to || edge.b != from) {
            throw ArgumentError(
              'Subdivision needs manifold edges with consistent winding.',
            );
          }
          edge.faceB = f;
          edge.oppositeB = opposite;
        }
      }
    }
    for (final edge in edges.values) {
      if (edge.faceB == null) {
        boundary[edge.a].add(edge.b);
        boundary[edge.b].add(edge.a);
      }
    }
    // Edge incidence alone misses two closed shells touching at one vertex.
    // Walk each vertex fan to reject these disconnected manifold links too.
    for (var v = 0; v < positions.length; v++) {
      if (incidents[v].isEmpty) continue;
      if (boundary[v].isNotEmpty && boundary[v].length != 2) {
        throw ArgumentError('Subdivision has a nonmanifold boundary vertex.');
      }
      final seen = <int>{};
      final pending = [incidents[v].first];
      while (pending.isNotEmpty) {
        final f = pending.removeLast();
        if (!seen.add(f)) continue;
        for (var corner = 0; corner < 3; corner++) {
          final other = faces[f + corner];
          if (other == v) continue;
          final edge = edges[_key(v, other)]!;
          if (!seen.contains(edge.faceA)) pending.add(edge.faceA);
          if (edge.faceB != null && !seen.contains(edge.faceB)) {
            pending.add(edge.faceB!);
          }
        }
      }
      if (seen.length != incidents[v].length) {
        throw ArgumentError(
          'Subdivision has disconnected faces at one vertex.',
        );
      }
    }
  }

  Vec3 even(int v) {
    final adjacent = neighbors[v];
    if (adjacent.isEmpty) return positions[v];
    final border = boundary[v];
    if (border.isNotEmpty) {
      return positions[v] * .75 +
          (positions[border[0]] + positions[border[1]]) * .125;
    }
    final beta = adjacent.length == 3 ? 3 / 16 : 3 / (8 * adjacent.length);
    return positions[v] * (1 - adjacent.length * beta) +
        adjacent.fold(Vec3.zero, (sum, i) => sum + positions[i]) * beta;
  }

  List<Vec3> normals() {
    final result = List.filled(positions.length, Vec3.zero);
    for (var f = 0; f < faces.length; f += 3) {
      final a = faces[f], b = faces[f + 1], c = faces[f + 2];
      final n = (positions[b] - positions[a]).cross(
        positions[c] - positions[a],
      );
      for (final i in [a, b, c]) {
        result[i] = result[i] + n;
      }
    }
    return result;
  }
}
