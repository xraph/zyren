import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Pinned, bounded float32 rows beside a policy sequence request.
final class SequenceObservations {
  final Uint8List _bytes;
  final int width;
  final Map<String, Object?> descriptor;
  SequenceObservations._(this._bytes, this.width, this.descriptor);

  static Future<SequenceObservations> load(
    File request,
    Object? value, {
    required int rows,
    required int width,
  }) async {
    if (value is! Map ||
        value.length != 5 ||
        value['path'] != 'observations.f32' ||
        value['dtype'] != 'float32-le' ||
        value['shape'] is! List ||
        (value['shape'] as List).length != 2 ||
        (value['shape'] as List)[0] is! int ||
        (value['shape'] as List)[1] is! int ||
        (value['shape'] as List)[0] != rows ||
        (value['shape'] as List)[1] != width ||
        rows < 1 ||
        rows > 2000 ||
        width < 1 ||
        width > 65536 ||
        value['bytes'] is! int ||
        value['bytes'] != rows * width * 4 ||
        rows * width * 4 > 268435456 ||
        value['sha256'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['sha256'] as String)) {
      throw StateError('Policy sequence sidecar descriptor differs.');
    }
    final file = File('${request.parent.path}/observations.f32');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Policy sequence sidecar must be a regular local file.');
    }
    final handle = await file.open();
    late Uint8List bytes;
    try {
      if (await handle.length() != value['bytes']) {
        throw StateError('Policy sequence sidecar byte count differs.');
      }
      bytes = await handle.read(value['bytes'] as int);
      if (bytes.length != value['bytes'] ||
          await handle.length() != value['bytes']) {
        throw StateError('Policy sequence sidecar changed during read.');
      }
    } finally {
      await handle.close();
    }
    if (sha256.convert(bytes).toString() != value['sha256']) {
      throw StateError('Policy sequence sidecar hash differs.');
    }
    final view = ByteData.sublistView(bytes);
    for (var offset = 0; offset < bytes.length; offset += 4) {
      if (!view.getFloat32(offset, Endian.little).isFinite) {
        throw StateError('Policy sequence sidecar contains a nonfinite value.');
      }
    }
    return SequenceObservations._(
      bytes,
      width,
      Map<String, Object?>.unmodifiable({
        ...value.cast<String, Object?>(),
        'shape': List<int>.unmodifiable([rows, width]),
      }),
    );
  }

  Float32List row(int index) {
    RangeError.checkValidIndex(
      index,
      _bytes,
      'row',
      _bytes.length ~/ (width * 4),
    );
    final view = ByteData.sublistView(
      _bytes,
      index * width * 4,
      (index + 1) * width * 4,
    );
    return Float32List.fromList([
      for (var i = 0; i < width; i++) view.getFloat32(i * 4, Endian.little),
    ]);
  }
}
