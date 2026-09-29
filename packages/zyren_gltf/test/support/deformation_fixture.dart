import 'dart:typed_data';
import 'dart:convert';
import 'fixtures.dart';

Uint8List deformationModel({
  String interpolation = 'LINEAR',
  List<double>? animationWeights,
  int weightType = 5126,
  int animationType = 5126,
  bool sparseMorph = false,
  void Function(ByteData, List<Map<String, Object?>>)? editBinary,
  bool inverseBind = true,
  void Function(Map<String, Object?>)? edit,
}) {
  final bytes = BytesBuilder();
  final views = <Map<String, Object?>>[], accessors = <Map<String, Object?>>[];
  int add(
    List<num> values,
    String type,
    int size, {
    int component = 5126,
    bool normalized = false,
    List<num>? min,
    List<num>? max,
  }) {
    final width = component == 5126
        ? 4
        : component == 5123
        ? 2
        : 1;
    final data = ByteData(values.length * width);
    for (var i = 0; i < values.length; i++) {
      if (component == 5126) {
        data.setFloat32(i * width, values[i].toDouble(), Endian.little);
      } else if (component == 5123) {
        data.setUint16(i * width, values[i].toInt(), Endian.little);
      } else {
        data.setUint8(i, values[i].toInt());
      }
    }
    views.add({
      'buffer': 0,
      'byteOffset': bytes.length,
      'byteLength': data.lengthInBytes,
    });
    bytes.add(data.buffer.asUint8List());
    while (bytes.length % 4 != 0) {
      bytes.add([0]);
    }
    accessors.add({
      'bufferView': views.length - 1,
      'componentType': component,
      'count': values.length ~/ size,
      'type': type,
      if (normalized) 'normalized': true,
      'min': ?min,
      'max': ?max,
    });
    return accessors.length - 1;
  }

  final position = add(
    [-1, -1, 0, 1, -1, 0, 0, 1, 0],
    'VEC3',
    3,
    min: [-1, -1, 0],
    max: [1, 1, 0],
  );
  final normal = add([0, 0, 1, 0, 0, 1, 0, 0, 1], 'VEC3', 3);
  final joint = add(
    [0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0],
    'VEC4',
    4,
    component: 5121,
  );
  final maximum = weightType == 5121 ? 255 : 65535;
  final weights = add(
    weightType == 5126
        ? [.5, .5, 0, 0, .5, .5, 0, 0, 1, 0, 0, 0]
        : [maximum, 0, 0, 0, maximum, 0, 0, 0, maximum, 0, 0, 0],
    'VEC4',
    4,
    component: weightType,
    normalized: weightType != 5126,
  );
  final morph = add(
    [0, 0, 1, 0, 0, 1, 0, 0, 1],
    'VEC3',
    3,
    min: [0, 0, 1],
    max: [0, 0, 1],
  );
  final times = add([0, 2], 'SCALAR', 1, min: [0], max: [2]);
  final keyValues =
      animationWeights ??
      (interpolation == 'CUBICSPLINE'
          ? [0.0, 0, 0, 0, 2, 0, 0, 0, 2, 4, 0, 0]
          : [0.0, 0, 2, 4]);
  final values = add(
    [
      for (final v in keyValues)
        animationType == 5126
            ? v
            : (v * (animationType == 5121 ? 255 : 65535)).round(),
    ],
    'SCALAR',
    1,
    component: animationType,
    normalized: animationType != 5126,
  );
  final matrices = add(
    [
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      -1,
      0,
      1,
    ],
    'MAT4',
    16,
  );
  if (sparseMorph) {
    final sparseIndices = add([0, 1, 2], 'SCALAR', 1, component: 5121);
    accessors[morph].remove('bufferView');
    accessors[morph]['sparse'] = {
      'count': 3,
      'indices': {
        'bufferView': accessors[sparseIndices]['bufferView'],
        'componentType': 5121,
      },
      'values': {'bufferView': morph},
    };
  }
  final root = <String, Object?>{
    'asset': {'version': '2.0'},
    'buffers': [
      {'byteLength': bytes.length},
    ],
    'bufferViews': views,
    'accessors': accessors,
    'meshes': [
      {
        'weights': [.1, .2],
        'primitives': [
          {
            'attributes': {
              'POSITION': position,
              'NORMAL': normal,
              'JOINTS_0': joint,
              'WEIGHTS_0': weights,
            },
            'targets': [
              {'POSITION': morph},
              {'POSITION': morph},
            ],
          },
        ],
      },
    ],
    'nodes': [
      {
        'children': [1, 2],
      },
      {
        'mesh': 0,
        'skin': 0,
        'weights': [.3, .4],
        'translation': [3, 0, 0],
      },
      {
        'children': [3],
      },
      {
        'translation': [0, 1, 0],
      },
    ],
    'skins': [
      {
        'joints': [2, 3],
        'skeleton': 2,
        if (inverseBind) 'inverseBindMatrices': matrices,
      },
    ],
    'scenes': [
      {
        'nodes': [0],
      },
    ],
    'animations': [
      {
        'samplers': [
          {'input': times, 'output': values, 'interpolation': interpolation},
        ],
        'channels': [
          {
            'sampler': 0,
            'target': {'node': 1, 'path': 'weights'},
          },
        ],
      },
    ],
  };
  final editable = (jsonDecode(jsonEncode(root)) as Map)
      .cast<String, Object?>();
  edit?.call(editable);
  final binary = bytes.takeBytes();
  editBinary?.call(ByteData.sublistView(binary), views);
  return glb(editable, binary: binary);
}
