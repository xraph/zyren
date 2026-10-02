import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../geodesy.dart';
import '../tiling.dart';
import 'terrain_tile.dart';

/// Count limits apply before allocation. Reservations cover final payloads;
/// bounded parser buffers and geometry construction also use temporary memory.
final class QuantizedMeshLimits {
  final int maxEncodedBytes, maxVertices, maxTriangles, maxEdgeVertices;
  QuantizedMeshLimits({
    this.maxEncodedBytes = 1024 * 1024,
    this.maxVertices = 8192,
    this.maxTriangles = 16384,
    this.maxEdgeVertices = 2048,
  }) {
    if (maxEncodedBytes < 128 ||
        maxEncodedBytes > 64 * 1024 * 1024 ||
        maxVertices < 3 ||
        maxVertices > 1000000 ||
        maxTriangles < 1 ||
        maxTriangles > 1000000 ||
        maxEdgeVertices < 8 ||
        maxEdgeVertices > 500000 ||
        maxVertices + maxEdgeVertices > 1000000 ||
        maxTriangles * 3 + maxEdgeVertices * 6 > 3000000) {
      throw ArgumentError(
        'Quantized mesh limits exceed supported geometry sizes.',
      );
    }
  }
  int get decodedBytes =>
      (maxVertices + maxEdgeVertices) * 32 +
      (maxTriangles * 3 + maxEdgeVertices * 6) * 4 +
      4;
  int get residentBytes =>
      (maxVertices + maxEdgeVertices) * 40 +
      (maxTriangles * 3 + maxEdgeVertices * 6) * 4 +
      4;
}

/// Quantized-mesh 1.0 CPU decoder. The rectangle uses EPSG:4326 radians.
/// Heights and skirts must fit the supplied envelope, also used for culling.
final class QuantizedMeshDecoder {
  final QuantizedMeshLimits limits;
  QuantizedMeshDecoder({QuantizedMeshLimits? limits})
    : limits = limits ?? QuantizedMeshLimits();

  TerrainTile decode(
    Uint8List bytes, {
    required GeographicRectangle rectangle,
    required LoadCancellation cancellation,
    double skirtDepth = 50,
    double minimumHeight = -12000,
    double maximumHeight = 10000,
  }) {
    cancellation.throwIfCancelled();
    if (bytes.length > limits.maxEncodedBytes) _limit();
    if (rectangle.toList().any((n) => !n.isFinite) ||
        rectangle.width <= 0 ||
        rectangle.width > 2 * math.pi ||
        rectangle.height <= 0 ||
        rectangle.south < -math.pi / 2 ||
        rectangle.north > math.pi / 2 ||
        !skirtDepth.isFinite ||
        skirtDepth < 0 ||
        skirtDepth > 100000 ||
        !minimumHeight.isFinite ||
        !maximumHeight.isFinite ||
        minimumHeight < -100000 ||
        maximumHeight > 100000 ||
        minimumHeight > maximumHeight) {
      throw ArgumentError(
        'Use geographic bounds and a finite terrain height envelope.',
      );
    }
    final reader = _Reader(bytes);
    // Bounds from an untrusted header never replace the source's own bounds.
    for (var i = 0; i < 3; i++) {
      reader.f64();
    }
    final low = reader.f32(), high = reader.f32();
    for (var i = 0; i < 3; i++) {
      reader.f64();
    }
    if (reader.f64() < 0) _invalid();
    for (var i = 0; i < 3; i++) {
      reader.f64();
    }
    if (low > high || low < minimumHeight || high > maximumHeight) _invalid();
    final count = reader.u32();
    if (count > limits.maxVertices) _limit();
    if (count < 3) _invalid();
    reader.require(count * 6);
    Uint16List axis() {
      final values = Uint16List(count);
      var previous = 0;
      for (var i = 0; i < count; i++) {
        if (i % 1024 == 0) cancellation.throwIfCancelled();
        final code = reader.u16();
        previous += (code >> 1) ^ -(code & 1);
        if (previous < 0 || previous > 32767) _invalid();
        values[i] = previous;
      }
      return values;
    }

    final u = axis(), v = axis(), heights = axis();
    final indexSize = count > 65536 ? 4 : 2;
    reader.skip((indexSize - reader.offset % indexSize) % indexSize);
    final triangles = reader.u32();
    if (triangles > limits.maxTriangles) _limit();
    if (triangles == 0) _invalid();
    reader.require(triangles * 3 * indexSize);
    final surfaceIndices = Uint32List(triangles * 3);
    var highest = 0;
    int index() => indexSize == 4 ? reader.u32() : reader.u16();
    for (var i = 0; i < surfaceIndices.length; i++) {
      if (i % 1024 == 0) cancellation.throwIfCancelled();
      final code = index(), value = highest - code;
      if (value < 0 || value >= count) _invalid();
      surfaceIndices[i] = value;
      if (code == 0) highest++;
    }
    var edgeCount = 0;
    final edges = <List<int>>[];
    for (var side = 0; side < 4; side++) {
      final length = reader.u32();
      edgeCount += length;
      if (edgeCount > limits.maxEdgeVertices) _limit();
      if (length < 2 || length > count) _invalid();
      reader.require(length * indexSize);
      final edge = List<int>.generate(length, (_) => index());
      if (edge.toSet().length != length) _invalid();
      for (final id in edge) {
        if (id >= count ||
            switch (side) {
              0 => u[id] != 0,
              1 => v[id] != 0,
              2 => u[id] != 32767,
              _ => v[id] != 32767,
            }) {
          _invalid();
        }
      }
      // Clockwise perimeter in east/north space makes skirt faces point out.
      int along(int id) => side.isEven ? v[id] : u[id];
      edge.sort(
        (a, b) => (side == 0 || side == 3)
            ? along(a).compareTo(along(b))
            : along(b).compareTo(along(a)),
      );
      if ({along(edge.first), along(edge.last)}.length != 2 ||
          math.min(along(edge.first), along(edge.last)) != 0 ||
          math.max(along(edge.first), along(edge.last)) != 32767) {
        _invalid();
      }
      edges.add(edge);
    }
    Uint8List? octNormals;
    final extensions = <int>{};
    while (reader.remaining != 0) {
      cancellation.throwIfCancelled();
      final id = reader.u8(), length = reader.u32();
      reader.require(length);
      if (!extensions.add(id)) _invalid();
      if (id == 1) {
        if (length != count * 2) _invalid();
        octNormals = Uint8List.sublistView(
          bytes,
          reader.offset,
          reader.offset + length,
        );
      }
      reader.skip(length);
    }
    final origin = Geodetic(
      rectangle.west + rectangle.width / 2,
      (rectangle.south + rectangle.north) / 2,
    ).toEcef();
    final total = count + edgeCount;
    final positions = Float64List(total * 3), normals = Float64List(total * 3);
    final uv = Float32List(total * 2);
    final indices = Uint32List(surfaceIndices.length + (edgeCount - 4) * 6);
    indices.setAll(0, surfaceIndices);
    Geodetic coordinate(int id, [double lowering = 0]) => Geodetic(
      rectangle.west + rectangle.width * (u[id] / 32767),
      rectangle.south + rectangle.height * (v[id] / 32767),
      low + (high - low) * (heights[id] / 32767) - lowering,
    );
    void vertex(int dest, int id, [double lowering = 0]) {
      final point = coordinate(id, lowering).toEcef() - origin;
      positions.setAll(dest * 3, [point.x, point.y, point.z]);
      uv[dest * 2] = u[id] / 32767;
      uv[dest * 2 + 1] = 1 - v[id] / 32767;
    }

    for (var i = 0; i < count; i++) {
      if (i % 1024 == 0) cancellation.throwIfCancelled();
      vertex(i, i);
    }
    if (octNormals == null) {
      for (var i = 0; i < surfaceIndices.length; i += 3) {
        final a = surfaceIndices[i],
            b = surfaceIndices[i + 1],
            c = surfaceIndices[i + 2];
        final normal =
            (Vec3.array(positions, b * 3) - Vec3.array(positions, a * 3)).cross(
              Vec3.array(positions, c * 3) - Vec3.array(positions, a * 3),
            );
        for (final id in [a, b, c]) {
          normals[id * 3] += normal.x;
          normals[id * 3 + 1] += normal.y;
          normals[id * 3 + 2] += normal.z;
        }
      }
    }
    for (var i = 0; i < count; i++) {
      var normal = octNormals == null
          ? Vec3.array(normals, i * 3)
          : _oct(octNormals[i * 2], octNormals[i * 2 + 1]);
      if (normal.length2 < 1e-20) {
        final at = coordinate(i);
        normal = Vec3(
          math.cos(at.latitude) * math.cos(at.longitude),
          math.cos(at.latitude) * math.sin(at.longitude),
          math.sin(at.latitude),
        );
      }
      normal = normal.normalized();
      normals.setAll(i * 3, [normal.x, normal.y, normal.z]);
    }
    var next = count, at = surfaceIndices.length;
    for (final edge in edges) {
      final start = next;
      for (final id in edge) {
        vertex(next, id, skirtDepth);
        normals.setRange(next * 3, next * 3 + 3, normals, id * 3);
        next++;
      }
      for (var i = 0; i < edge.length - 1; i++) {
        final a = edge[i], b = edge[i + 1], c = start + i, d = c + 1;
        indices.setAll(at, [a, b, c, b, d, c]);
        at += 6;
      }
    }
    cancellation.throwIfCancelled();
    return TerrainTile(
      origin: origin,
      geometry: BufferGeometry(
        positions: positions,
        normals: normals,
        uv0: uv,
        indices: indices,
      ),
      imagery: TextureImage.rgba(
        width: 1,
        height: 1,
        pixels: Uint8List.fromList([176, 188, 157, 255]),
      ),
      imageryRectangle: rectangle,
    );
  }
}

Vec3 _oct(int a, int b) {
  var x = a / 255 * 2 - 1, y = b / 255 * 2 - 1;
  final z = 1 - x.abs() - y.abs();
  if (z < 0) {
    final oldX = x;
    x = (1 - y.abs()) * (x < 0 ? -1 : 1);
    y = (1 - oldX.abs()) * (y < 0 ? -1 : 1);
  }
  return Vec3(x, y, z).normalized();
}

Never _invalid() => throw AssetLoadException(
  AssetLoadError.invalidData,
  'Invalid quantized terrain data.',
);
Never _limit() => throw AssetLoadException(
  AssetLoadError.limitExceeded,
  'Quantized terrain exceeds its decode limits.',
);

final class _Reader {
  final ByteData data;
  int offset = 0;
  _Reader(Uint8List bytes) : data = ByteData.sublistView(bytes);
  int get remaining => data.lengthInBytes - offset;
  void require(int length) {
    if (length < 0 || length > remaining) _invalid();
  }

  void skip(int length) {
    require(length);
    offset += length;
  }

  int u8() {
    require(1);
    return data.getUint8(offset++);
  }

  int u16() {
    require(2);
    final n = data.getUint16(offset, Endian.little);
    offset += 2;
    return n;
  }

  int u32() {
    require(4);
    final n = data.getUint32(offset, Endian.little);
    offset += 4;
    return n;
  }

  double f32() {
    require(4);
    final n = data.getFloat32(offset, Endian.little);
    offset += 4;
    if (!n.isFinite) _invalid();
    return n;
  }

  double f64() {
    require(8);
    final n = data.getFloat64(offset, Endian.little);
    offset += 8;
    if (!n.isFinite) _invalid();
    return n;
  }
}
