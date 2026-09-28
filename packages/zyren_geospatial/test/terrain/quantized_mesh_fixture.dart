import 'dart:typed_data';
import 'package:zyren/zyren.dart';

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
