import 'dart:typed_data';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';

/// A synthetic terrain grid for transport and native rendering checks.
Uint8List gridMeshFixture({int segments = 12}) {
  final out = BytesBuilder();
  void u16(int n) => out.add(
    (ByteData(2)..setUint16(0, n, Endian.little)).buffer.asUint8List(),
  );
  void u32(int n) => out.add(
    (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List(),
  );
  void f64(double n) => out.add(
    (ByteData(8)..setFloat64(0, n, Endian.little)).buffer.asUint8List(),
  );
  void f32(double n) => out.add(
    (ByteData(4)..setFloat32(0, n, Endian.little)).buffer.asUint8List(),
  );
  for (var i = 0; i < 3; i++) {
    f64(0);
  }
  f32(0);
  f32(1000);
  for (final n in [0.0, 0.0, 0.0, 7000000.0, 0.0, 0.0, 0.0]) {
    f64(n);
  }
  final order = <int, int>{}, indices = <int>[];
  for (var y = 0; y < segments; y++) {
    for (var x = 0; x < segments; x++) {
      final a = y * (segments + 1) + x, b = a + segments + 1;
      for (final id in [a, a + 1, b, b, a + 1, b + 1]) {
        indices.add(order.putIfAbsent(id, () => order.length));
      }
    }
  }
  u32(order.length);
  final ids = order.keys.toList();
  for (var axis = 0; axis < 3; axis++) {
    var previous = 0;
    for (final id in ids) {
      final x = (id % (segments + 1)) / segments,
          y = (id ~/ (segments + 1)) / segments;
      final value =
          ((axis == 0
                      ? x
                      : axis == 1
                      ? y
                      : math.sin(x * math.pi) * math.sin(y * math.pi)) *
                  32767)
              .round();
      final delta = value - previous;
      u16((delta << 1) ^ (delta >> 31));
      previous = value;
    }
  }
  u32(indices.length ~/ 3);
  var highest = 0;
  for (final id in indices) {
    final code = highest - id;
    u16(code);
    if (code == 0) highest++;
  }
  for (final edge in [
    [for (var y = 0; y <= segments; y++) y * (segments + 1)],
    [for (var x = 0; x <= segments; x++) x],
    [for (var y = 0; y <= segments; y++) y * (segments + 1) + segments],
    [for (var x = 0; x <= segments; x++) segments * (segments + 1) + x],
  ]) {
    u32(edge.length);
    for (final id in edge) {
      u16(order[id]!);
    }
  }
  return out.takeBytes();
}

/// Independent writer for the published wire layout, with deliberately unsorted
/// edge lists. Extra vertices exercise the 16/32-bit alignment boundary.
Uint8List meshFixture({int vertexCount = 4, bool normals = false}) {
  final out = BytesBuilder();
  void u16(int n) => out.add(
    (ByteData(2)..setUint16(0, n, Endian.little)).buffer.asUint8List(),
  );
  void u32(int n) => out.add(
    (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List(),
  );
  void f64(double n) => out.add(
    (ByteData(8)..setFloat64(0, n, Endian.little)).buffer.asUint8List(),
  );
  void f32(double n) => out.add(
    (ByteData(4)..setFloat32(0, n, Endian.little)).buffer.asUint8List(),
  );
  for (var i = 0; i < 3; i++) {
    f64(0);
  }
  f32(100);
  f32(200);
  for (final n in [0.0, 0.0, 0.0, 7000000.0, 0.0, 0.0, 0.0]) {
    f64(n);
  }
  u32(vertexCount);
  for (final axis in [
    [0, 32767, 0, 32767],
    [0, 0, 32767, 32767],
    [0, 0, 0, 32767],
  ]) {
    var previous = 0;
    for (var i = 0; i < vertexCount; i++) {
      final value = i < 4 ? axis[i] : 0;
      final delta = value - previous;
      u16((delta << 1) ^ (delta >> 31));
      previous = value;
    }
  }
  final size = vertexCount > 65536 ? 4 : 2;
  while (out.length % size != 0) {
    out.add([0]);
  }
  final index = size == 4 ? u32 : u16;
  u32(2);
  // Decodes to [0,1,2, 2,1,3], counterclockwise in east/north coordinates.
  for (final n in [0, 0, 0, 1, 2, 0]) {
    index(n);
  }
  for (final edge in [
    [2, 0],
    [1, 0],
    [1, 3],
    [2, 3],
  ]) {
    u32(edge.length);
    edge.forEach(index);
  }
  if (normals) {
    out.add([1]);
    u32(vertexCount * 2);
    for (var i = 0; i < vertexCount; i++) {
      out.add([255, 128]);
    }
  }
  return out.takeBytes();
}

class TestCancellation implements LoadCancellation {
  final _callbacks = <void Function()>{};
  @override
  bool isCancelled = false;
  @override
  void throwIfCancelled() {
    if (isCancelled) throw LoadCancelled();
  }

  @override
  Registration onCancel(void Function() callback) {
    if (isCancelled) {
      callback();
      return Registration(() {});
    }
    _callbacks.add(callback);
    return Registration(() => _callbacks.remove(callback));
  }

  void cancel() {
    isCancelled = true;
    for (final callback in _callbacks.toList()) {
      callback();
    }
    _callbacks.clear();
  }
}
