part of '../zyren_3d_tiles.dart';

ModelPropertyTable _batchProperties(
  Map<String, dynamic> json,
  Uint8List binary,
  int count,
  AssetDecodeContext context,
  GltfLimits limits,
) {
  if (count > limits.maxObjects || json.length > limits.maxObjects) _limit();
  if (json.containsKey('extensions')) _unsupported();
  context.reserveDecodedBytes(count * (json.isEmpty ? 1 : json.length) * 32);
  final columns = <String, List<Object?>>{};
  final bytes = ByteData.sublistView(binary);
  for (final entry in json.entries) {
    if (entry.key == 'extras') continue;
    final value = entry.value;
    if (value is List) {
      if (value.length != count) _invalid();
      columns[entry.key] = value.cast<Object?>();
      continue;
    }
    final descriptor = _object(value), offset = descriptor['byteOffset'];
    final (size, read) = switch (descriptor['componentType']) {
      'BYTE' => (1, (int at) => bytes.getInt8(at)),
      'UNSIGNED_BYTE' => (1, (int at) => bytes.getUint8(at)),
      'SHORT' => (2, (int at) => bytes.getInt16(at, Endian.little)),
      'UNSIGNED_SHORT' => (2, (int at) => bytes.getUint16(at, Endian.little)),
      'INT' => (4, (int at) => bytes.getInt32(at, Endian.little)),
      'UNSIGNED_INT' => (4, (int at) => bytes.getUint32(at, Endian.little)),
      'FLOAT' => (4, (int at) => bytes.getFloat32(at, Endian.little)),
      'DOUBLE' => (8, (int at) => bytes.getFloat64(at, Endian.little)),
      _ => _invalid(),
    };
    final components = switch (descriptor['type']) {
      'SCALAR' => 1,
      'VEC2' => 2,
      'VEC3' => 3,
      'VEC4' => 4,
      _ => _invalid(),
    };
    final length = count * components * size;
    if (offset is! int ||
        offset < 0 ||
        offset % size != 0 ||
        offset > binary.length - length) {
      _invalid();
    }
    context.reserveDecodedBytes(count * components * 16);
    columns[entry.key] = [
      for (var i = 0; i < count; i++)
        if (components == 1)
          _finiteProperty(read(offset + i * size))
        else
          [
            for (var c = 0; c < components; c++)
              _finiteProperty(read(offset + (i * components + c) * size)),
          ],
    ];
  }
  return ModelPropertyTable(count: count, columns: columns);
}

num _finiteProperty(num value) {
  if (!value.isFinite) _invalid();
  return value;
}
