import 'dart:typed_data';
import 'dart:convert';
import 'fixtures.dart';

Uint8List animatedModel({
  bool skin = true,
  bool morph = true,
  double bindPosition = 0,
  String interpolation = 'LINEAR',
  void Function(Map<String, Object?>)? mutate,
}) {
  final bytes = <int>[],
      views = <Map<String, Object?>>[],
      accessors = <Map<String, Object?>>[];
  int floats(
    List<double> values,
    String type,
    int count, {
    bool position = false,
  }) {
    final data = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      data.setFloat32(i * 4, values[i], Endian.little);
    }
    final view = views.length;
    views.add({
      'buffer': 0,
      'byteOffset': bytes.length,
      'byteLength': data.lengthInBytes,
    });
    bytes.addAll(data.buffer.asUint8List());
    accessors.add({
      'bufferView': view,
      'componentType': 5126,
      'type': type,
      'count': count,
      if (position) 'min': [-1, -1, 0],
      if (position) 'max': [1, 1, 0],
    });
    return accessors.length - 1;
  }

  final p = floats([-1, -1, 0, 1, -1, 0, 0, 1, 0], 'VEC3', 3, position: true);
  final n = floats([0, 0, 1, 0, 0, 1, 0, 0, 1], 'VEC3', 3);
  final time = floats([0, 1], 'SCALAR', 2);
  accessors[time]['min'] = [0];
  accessors[time]['max'] = [1];
  final translation = floats(
    interpolation == 'CUBICSPLINE'
        ? [0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0]
        : [bindPosition, 0, 0, bindPosition + 4, 0, 0],
    'VEC3',
    interpolation == 'CUBICSPLINE' ? 6 : 2,
  );
  final attributes = <String, Object?>{'POSITION': p, 'NORMAL': n};
  if (skin) {
    final view = views.length;
    views.add({'buffer': 0, 'byteOffset': bytes.length, 'byteLength': 24});
    final data = ByteData(24);
    bytes.addAll(data.buffer.asUint8List());
    accessors.add({
      'bufferView': view,
      'componentType': 5123,
      'type': 'VEC4',
      'count': 3,
    });
    attributes['JOINTS_0'] = accessors.length - 1;
    attributes['WEIGHTS_0'] = floats(
      [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0],
      'VEC4',
      3,
    );
  }
  final target = morph ? floats([4, 0, 0, 4, 0, 0, 4, 0, 0], 'VEC3', 3) : null;
  if (target != null) {
    accessors[target]['min'] = [4, 0, 0];
    accessors[target]['max'] = [4, 0, 0];
  }
  final weight = morph ? floats([0, 1], 'SCALAR', 2) : null;
  final inverseBind = bindPosition == 0
      ? null
      : floats(
          [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -bindPosition, 0, 0, 1],
          'MAT4',
          1,
        );
  final root = <String, Object?>{
    'asset': {'version': '2.0'},
    'extensionsUsed': ['KHR_materials_unlit'],
    'buffers': [
      {'byteLength': bytes.length},
    ],
    'bufferViews': views,
    'accessors': accessors,
    'materials': [
      {
        'extensions': {'KHR_materials_unlit': <String, Object?>{}},
        'pbrMetallicRoughness': {
          'baseColorFactor': [1, 0, 0, 1],
        },
      },
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': attributes,
            'material': 0,
            if (morph)
              'targets': [
                {'POSITION': target},
              ],
          },
        ],
        if (morph) 'weights': [0],
      },
    ],
    'nodes': [
      {'mesh': 0, if (skin) 'skin': 0},
      {
        'name': 'joint',
        'translation': [bindPosition, 0, 0],
      },
    ],
    if (skin)
      'skins': [
        {
          'joints': [1],
          'inverseBindMatrices': ?inverseBind,
        },
      ],
    'scenes': [
      {
        'nodes': [0, 1],
      },
    ],
    'scene': 0,
    'animations': [
      {
        'name': 'move',
        'samplers': [
          {
            'input': time,
            'output': translation,
            'interpolation': interpolation,
          },
          if (morph) {'input': time, 'output': weight},
        ],
        'channels': [
          {
            'sampler': 0,
            'target': {'node': skin ? 1 : 0, 'path': 'translation'},
          },
          if (morph)
            {
              'sampler': 1,
              'target': {'node': 0, 'path': 'weights'},
            },
        ],
        'extras': {
          'zyrenEvents': [
            {'id': 'start', 'time': 0},
            {'id': 'middle', 'time': .5},
            {'id': 'end', 'time': 1},
          ],
        },
      },
    ],
  };
  final mutable = jsonDecode(jsonEncode(root)) as Map<String, Object?>;
  mutate?.call(mutable);
  return glb(mutable, binary: bytes);
}
