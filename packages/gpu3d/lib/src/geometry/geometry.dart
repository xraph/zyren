import 'dart:math' as math;
import 'dart:typed_data';
import '../math/vec3.dart';
import 'vertex_attribute.dart';
import 'vertex_layout.dart';
part 'geometry_snapshot.dart';
part 'primitives.dart';

enum GeometryTopology { triangles, lineSegments, lineStrip, points }

enum IndexFormat {
  uint16,
  uint32;

  int get bytesPerIndex => this == uint16 ? 2 : 4;
}

/// Indexed geometry with an optional fixed-layout update path.
class BufferGeometry {
  static int _nextId = 1;
  final int id = _nextId++;
  final bool isDynamic;
  late GeometrySnapshot _snapshot;
  final _dependents = <(WeakReference<Object>, void Function(Object))>[];
  GeometryTopology get topology => _snapshot.topology;
  IndexFormat get indexFormat => _snapshot.indexFormat;
  int get revision => _snapshot.revision;
  int get vertexCount => _snapshot.layout.vertexCount;
  VertexLayout get layout => _snapshot.layout;
  Map<VertexSemantic, VertexAttribute> get attributes => _snapshot.attributes;
  List<double> get positions => _snapshot.positions;
  List<double> get normals => _snapshot.normals;
  List<int> get indices => _snapshot.indices;
  List<double>? get uv0 => _snapshot.uv0;
  List<double>? get uv1 => _snapshot.uv1;
  GeometrySnapshot capture() => _snapshot;

  BufferGeometry({
    required List<double> positions,
    required List<double> normals,
    required List<int> indices,
    IndexFormat indexFormat = IndexFormat.uint32,
    GeometryTopology topology = GeometryTopology.triangles,
    List<double>? uv0,
    List<double>? uv1,
    bool dynamic = false,
  }) : this.fromAttributes(
         attributes: {
           VertexSemantic.position: VertexAttribute(
             Float32List.fromList(positions),
             format: VertexFormat.float32x3,
           ),
           VertexSemantic.normal: VertexAttribute(
             Float32List.fromList(normals),
             format: VertexFormat.float32x3,
           ),
           if (uv0 != null)
             VertexSemantic.uv0: VertexAttribute(
               Float32List.fromList(uv0),
               format: VertexFormat.float32x2,
             ),
           if (uv1 != null)
             VertexSemantic.uv1: VertexAttribute(
               Float32List.fromList(uv1),
               format: VertexFormat.float32x2,
             ),
         },
         indices: indices,
         topology: topology,
         indexFormat: indexFormat,
         dynamic: dynamic,
       );

  BufferGeometry.fromAttributes({
    required Map<VertexSemantic, VertexAttribute> attributes,
    required List<int> indices,
    IndexFormat indexFormat = IndexFormat.uint32,
    GeometryTopology topology = GeometryTopology.triangles,
    bool dynamic = false,
  }) : isDynamic = dynamic {
    final layout = VertexLayout(attributes);
    if (indices.isEmpty ||
        indices.length > 3000000 ||
        (topology == GeometryTopology.triangles && indices.length % 3 != 0) ||
        (topology == GeometryTopology.lineSegments &&
            indices.length % 2 != 0) ||
        (topology == GeometryTopology.lineStrip && indices.length < 2) ||
        indices.any(
          (i) =>
              i < 0 ||
              i >= layout.vertexCount ||
              (indexFormat == IndexFormat.uint16 && i > 65535),
        )) {
      throw ArgumentError(
        'Indices must fit the topology, vertex count and ${indexFormat.name} range.',
      );
    }
    final primitiveCount = switch (topology) {
      GeometryTopology.triangles => indices.length ~/ 3,
      GeometryTopology.lineSegments => indices.length ~/ 2,
      GeometryTopology.lineStrip => indices.length - 1,
      GeometryTopology.points => indices.length,
    };
    if (topology != GeometryTopology.triangles && primitiveCount > 250000) {
      throw ArgumentError('Expanded primitives support at most 250000 quads.');
    }
    _snapshot = GeometrySnapshot._(
      id: id,
      logicalId: id,
      revision: 0,
      layout: layout,
      topology: topology,
      attributes: attributes,
      indexFormat: indexFormat,
      indices: indexFormat == IndexFormat.uint16
          ? Uint16List.fromList(indices).asUnmodifiableView()
          : Uint32List.fromList(indices).asUnmodifiableView(),
      history: const [],
    );
  }

  /// Replaces complete vertices in an existing attribute, without changing layout.
  /// Input is copied. Invalid edits leave data, revision and scene state intact.
  void updateAttribute(
    VertexSemantic semantic,
    TypedData values, {
    int firstVertex = 0,
  }) {
    if (!isDynamic) {
      throw StateError(
        'Create geometry with dynamic: true to update attributes.',
      );
    }
    final old = attributes[semantic];
    if (old == null) {
      throw ArgumentError('Geometry has no ${semantic.name} attribute.');
    }
    final update = VertexAttribute(values, format: old.format);
    VertexLayout.validate(semantic, update);
    RangeError.checkValueInInterval(firstVertex, 0, vertexCount, 'firstVertex');
    if (update.count > vertexCount - firstVertex) {
      throw RangeError('Attribute update exceeds vertex count.');
    }
    final bytes = old.data.buffer.asUint8List(
      old.data.offsetInBytes,
      old.data.lengthInBytes,
    );
    final changed = update.data.buffer.asUint8List(
      update.data.offsetInBytes,
      update.data.lengthInBytes,
    );
    final offset = firstVertex * old.format.stride;
    var different = false;
    for (var i = 0; i < changed.length; i++) {
      different |= bytes[offset + i] != changed[i];
    }
    if (!different) return;
    final copy = Uint8List.fromList(bytes)
      ..setRange(offset, offset + changed.length, changed);
    final TypedData data = switch (old.format) {
      VertexFormat.uint16x4 => copy.buffer.asUint16List(),
      VertexFormat.uint32x4 => copy.buffer.asUint32List(),
      VertexFormat.unorm8x4 => copy,
      _ => copy.buffer.asFloat32List(),
    };
    final next = revision + 1;
    _snapshot = GeometrySnapshot._(
      id: _nextId++,
      logicalId: id,
      revision: next,
      layout: layout,
      topology: topology,
      attributes: {
        ...attributes,
        semantic: VertexAttribute(data, format: old.format),
      },
      indices: indices,
      indexFormat: indexFormat,
      history: [
        ..._snapshot.history.skip(_snapshot.history.length >= 64 ? 1 : 0),
        GeometryChange(
          next,
          GeometryRange(semantic, firstVertex, update.count),
        ),
      ],
    );
    _dependents.removeWhere((entry) => entry.$1.target == null);
    for (final (reference, notify) in List.of(_dependents)) {
      final target = reference.target;
      if (target != null) notify(target);
    }
  }

  Map<String, Object> toNative() => _snapshot.toNative();
}

/// Internal scene invalidation without keeping removed meshes alive.
void watchGeometry(
  BufferGeometry geometry,
  Object dependent,
  void Function(Object) notify,
) {
  if (geometry.isDynamic) {
    geometry._dependents.add((WeakReference(dependent), notify));
  }
}

/// An XY plane facing +Z with top-left-origin UVs.
class PlaneGeometry extends BufferGeometry {
  factory PlaneGeometry({
    double width = 1,
    double height = 1,
    bool dynamic = false,
    IndexFormat indexFormat = IndexFormat.uint32,
  }) {
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      throw ArgumentError('Plane dimensions must be finite and positive.');
    }
    return PlaneGeometry._(width / 2, height / 2, dynamic, indexFormat);
  }
  PlaneGeometry._(double x, double y, bool dynamic, IndexFormat indexFormat)
    : super(
        dynamic: dynamic,
        indexFormat: indexFormat,
        positions: [-x, -y, 0, x, -y, 0, x, y, 0, -x, y, 0],
        normals: [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
        indices: [0, 1, 2, 0, 2, 3],
        uv0: [0, 1, 1, 1, 1, 0, 0, 0],
      );
}

class BoxGeometry extends BufferGeometry {
  factory BoxGeometry({
    double width = 1,
    double height = 1,
    double depth = 1,
    bool dynamic = false,
    IndexFormat indexFormat = IndexFormat.uint32,
  }) {
    if ([width, height, depth].any((v) => !v.isFinite || v <= 0)) {
      throw ArgumentError('Box dimensions must be finite and positive.');
    }
    final p = <double>[], n = <double>[], uv = <double>[];
    final indices = <int>[];
    final corners = [
      [1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, 1.0, 1.0, -1.0, 1.0],
      [-1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0, -1.0, -1.0, -1.0],
      [-1.0, 1.0, -1.0, -1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, -1.0],
      [-1.0, -1.0, 1.0, -1.0, -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0],
      [-1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, 1.0, 1.0, -1.0, 1.0, 1.0],
      [1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0],
    ];
    final faceNormals = [
      [1.0, 0.0, 0.0],
      [-1.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
      [0.0, -1.0, 0.0],
      [0.0, 0.0, 1.0],
      [0.0, 0.0, -1.0],
    ];
    for (var f = 0; f < 6; f++) {
      for (var i = 0; i < 12; i += 3) {
        p.addAll([
          corners[f][i] * width / 2,
          corners[f][i + 1] * height / 2,
          corners[f][i + 2] * depth / 2,
        ]);
        n.addAll(faceNormals[f]);
      }
      uv.addAll(switch (f) {
        0 || 1 => [1, 1, 1, 0, 0, 0, 0, 1],
        2 || 3 => [0, 0, 0, 1, 1, 1, 1, 0],
        _ => [0, 1, 1, 1, 1, 0, 0, 0],
      });
      final o = f * 4;
      indices.addAll([o, o + 1, o + 2, o, o + 2, o + 3]);
    }
    return BoxGeometry._(p, n, uv, indices, dynamic, indexFormat);
  }
  BoxGeometry._(
    List<double> p,
    List<double> n,
    List<double> uv,
    List<int> i,
    bool dynamic,
    IndexFormat indexFormat,
  ) : super(
        positions: p,
        normals: n,
        uv0: uv,
        indices: i,
        dynamic: dynamic,
        indexFormat: indexFormat,
      );
}

/// A Y-up sphere with indexed triangle geometry.
class SphereGeometry extends BufferGeometry {
  factory SphereGeometry({
    double radius = 1,
    int widthSegments = 64,
    int heightSegments = 32,
    bool dynamic = false,
    IndexFormat indexFormat = IndexFormat.uint32,
  }) {
    if (!radius.isFinite ||
        radius <= 0 ||
        widthSegments < 3 ||
        heightSegments < 2 ||
        (widthSegments + 1) * (heightSegments + 1) > 1000000) {
      throw ArgumentError('Invalid sphere radius or segment count.');
    }
    final p = <double>[], n = <double>[], uv = <double>[];
    final indices = <int>[];
    for (var y = 0; y <= heightSegments; y++) {
      final phi = math.pi * y / heightSegments;
      for (var x = 0; x <= widthSegments; x++) {
        final theta = x == widthSegments
            ? 0.0
            : 2 * math.pi * x / widthSegments;
        final atPole = y == 0 || y == heightSegments;
        final normal = [
          atPole ? 0.0 : math.sin(phi) * math.cos(theta),
          math.cos(phi),
          atPole ? 0.0 : math.sin(phi) * math.sin(theta),
        ];
        n.addAll(normal);
        p.addAll(normal.map((v) => v * radius));
        // Each used pole vertex takes the midpoint U of its cap triangle.
        final u = y == 0 && x > 0
            ? (x - .5) / widthSegments
            : y == heightSegments && x < widthSegments
            ? (x + .5) / widthSegments
            : x / widthSegments;
        uv.addAll([u, y / heightSegments]);
      }
    }
    for (var y = 0; y < heightSegments; y++) {
      for (var x = 0; x < widthSegments; x++) {
        final a = y * (widthSegments + 1) + x, b = a + widthSegments + 1;
        if (y > 0) indices.addAll([a, a + 1, b]);
        if (y < heightSegments - 1) indices.addAll([a + 1, b + 1, b]);
      }
    }
    return SphereGeometry._(p, n, uv, indices, dynamic, indexFormat);
  }
  SphereGeometry._(
    List<double> p,
    List<double> n,
    List<double> uv,
    List<int> i,
    bool dynamic,
    IndexFormat indexFormat,
  ) : super(
        positions: p,
        normals: n,
        uv0: uv,
        indices: i,
        dynamic: dynamic,
        indexFormat: indexFormat,
      );
}
