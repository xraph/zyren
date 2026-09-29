import 'dart:typed_data';
import 'fixtures.dart';

/// One mesh under an animated parent. Input/output accessors are 1 and 2.
Uint8List animatedModel({
  List<double> times = const [0, 2],
  List<double> values = const [0, 0, 0, 0, 1, 0],
  String path = 'translation',
  String interpolation = 'LINEAR',
  int componentType = 5126,
  void Function(Map<String, Object?>)? edit,
}) {
  final width = switch (componentType) {
    5120 || 5121 => 1,
    5122 || 5123 => 2,
    _ => 4,
  };
  final data = ByteData(times.length * 4 + values.length * width);
  for (var i = 0; i < times.length; i++) {
    data.setFloat32(i * 4, times[i], Endian.little);
  }
  for (var i = 0; i < values.length; i++) {
    final at = times.length * 4 + i * width, v = values[i];
    switch (componentType) {
      case 5120:
        data.setInt8(at, (v * 127).round());
      case 5121:
        data.setUint8(at, (v * 255).round());
      case 5122:
        data.setInt16(at, (v * 32767).round(), Endian.little);
      case 5123:
        data.setUint16(at, (v * 65535).round(), Endian.little);
      default:
        data.setFloat32(at, v, Endian.little);
    }
  }
  return editModel(triangleModel(), (root) {
    (root['bufferViews'] as List).addAll([
      {'buffer': 0, 'byteOffset': 36, 'byteLength': times.length * 4},
      {
        'buffer': 0,
        'byteOffset': 36 + times.length * 4,
        'byteLength': values.length * width,
      },
    ]);
    (root['accessors'] as List).addAll([
      {
        'bufferView': 1,
        'componentType': 5126,
        'count': times.length,
        'type': 'SCALAR',
        'min': [times.first],
        'max': [times.last],
      },
      {
        'bufferView': 2,
        'componentType': componentType,
        if (componentType != 5126) 'normalized': true,
        'count': values.length ~/ (path == 'rotation' ? 4 : 3),
        'type': path == 'rotation' ? 'VEC4' : 'VEC3',
      },
    ]);
    root['animations'] = [
      {
        'name': 'Lift',
        'samplers': [
          {'input': 1, 'output': 2, 'interpolation': interpolation},
        ],
        'channels': [
          {
            'sampler': 0,
            'target': {'node': 0, 'path': path},
          },
        ],
      },
    ];
    edit?.call(root);
  }, appendBinary: data.buffer.asUint8List());
}
