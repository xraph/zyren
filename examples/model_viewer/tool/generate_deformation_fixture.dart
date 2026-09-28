import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:model_viewer/deformation_scene.dart';

// Authored ribbons with shared source geometry and independent joint hierarchies.
void main() {
  final geometry = deformationRibbon();
  final bytes = BytesBuilder();
  final views = <Map<String, Object?>>[], accessors = <Map<String, Object?>>[];
  int accessor(
    List<num> values,
    String type,
    int components, {
    bool integer = false,
    bool bounds = false,
  }) {
    final data = ByteData(values.length * (integer ? 2 : 4));
    for (var i = 0; i < values.length; i++) {
      if (integer) {
        data.setUint16(i * 2, values[i].toInt(), Endian.little);
      } else {
        data.setFloat32(i * 4, values[i].toDouble(), Endian.little);
      }
    }
    final packed = integer ? null : data.buffer.asFloat32List();
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
      'componentType': integer ? 5123 : 5126,
      'count': values.length ~/ components,
      'type': type,
      if (bounds)
        'min': [
          for (var c = 0; c < components; c++)
            [
              for (var i = c; i < values.length; i += components) packed![i],
            ].reduce((a, b) => a < b ? a : b),
        ],
      if (bounds)
        'max': [
          for (var c = 0; c < components; c++)
            [
              for (var i = c; i < values.length; i += components) packed![i],
            ].reduce((a, b) => a > b ? a : b),
        ],
    });
    return accessors.length - 1;
  }

  final position = accessor(geometry.positions, 'VEC3', 3, bounds: true);
  final normal = accessor(geometry.normals, 'VEC3', 3);
  final joints = accessor(
    geometry.attributes[VertexSemantic.joints]!.data as List<int>,
    'VEC4',
    4,
    integer: true,
  );
  final weights = accessor(
    geometry.attributes[VertexSemantic.weights]!.data as List<double>,
    'VEC4',
    4,
  );
  final indices = accessor(geometry.indices, 'SCALAR', 1, integer: true);
  final morph = accessor(
    geometry.morphTargets.single.positions!,
    'VEC3',
    3,
    bounds: true,
  );
  final binds = accessor(
    [
      ...Mat4.compose(const Vec3(0, .9, 0), Quat.identity, Vec3.one).storage,
      ...Mat4.identity().storage,
    ],
    'MAT4',
    16,
  );
  final time = accessor([0, 1, 2, 3, 4], 'SCALAR', 1, bounds: true);
  final rotation = accessor(
    [
      for (final angle in [0.0, .85, 0.0, -.6, 0.0])
        ...Quat.axisAngle(const Vec3(0, 0, 1), angle).toVectorMath().storage,
    ],
    'VEC4',
    4,
  );
  final morphAnimation = accessor([0, 1, 0, -.3, 0], 'SCALAR', 1);
  final root = <String, Object?>{
    'asset': {
      'version': '2.0',
      'generator': 'gpu3d authored deformation fixture',
    },
    'buffers': [
      {'byteLength': bytes.length},
    ],
    'bufferViews': views,
    'accessors': accessors,
    'materials': [
      {
        'doubleSided': true,
        'pbrMetallicRoughness': {
          'baseColorFactor': [.1, .65, 1, 1],
          'metallicFactor': 0,
          'roughnessFactor': .65,
        },
      },
    ],
    'meshes': [
      {
        'name': 'Ribbon',
        'weights': [0],
        'extras': {
          'targetNames': ['width'],
        },
        'primitives': [
          {
            'attributes': {
              'POSITION': position,
              'NORMAL': normal,
              'JOINTS_0': joints,
              'WEIGHTS_0': weights,
            },
            'indices': indices,
            'material': 0,
            'targets': [
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
        'name': 'Animated',
        'translation': [-.6, 0, 0],
        'children': [3, 4],
      },
      {
        'name': 'Independent',
        'translation': [.6, 0, 0],
        'children': [6, 7],
      },
      {'mesh': 0, 'skin': 0},
      {
        'translation': [0, -.9, 0],
        'children': [5],
      },
      {
        'translation': [0, .9, 0],
      },
      {
        'mesh': 0,
        'skin': 1,
        'weights': [.3],
      },
      {
        'translation': [0, -.9, 0],
        'children': [8],
      },
      {
        'translation': [0, .9, 0],
        'rotation': Quat.axisAngle(
          const Vec3(0, 0, 1),
          -.4,
        ).toVectorMath().storage.toList(),
      },
    ],
    'skins': [
      {
        'joints': [4, 5],
        'skeleton': 4,
        'inverseBindMatrices': binds,
      },
      {
        'joints': [7, 8],
        'skeleton': 7,
        'inverseBindMatrices': binds,
      },
    ],
    'scenes': [
      {
        'name': 'Skinned ribbons',
        'nodes': [0],
      },
    ],
    'animations': [
      {
        'name': 'Bend and width',
        'samplers': [
          {'input': time, 'output': rotation},
          {'input': time, 'output': morphAnimation},
        ],
        'channels': [
          {
            'sampler': 0,
            'target': {'node': 5, 'path': 'rotation'},
          },
          {
            'sampler': 1,
            'target': {'node': 3, 'path': 'weights'},
          },
        ],
      },
    ],
  };
  final json = utf8.encode(jsonEncode(root));
  final jsonLength = (json.length + 3) & ~3;
  final output = Uint8List(28 + jsonLength + bytes.length);
  final header = ByteData.sublistView(output);
  for (final entry in [
    (0, 0x46546c67),
    (4, 2),
    (8, output.length),
    (12, jsonLength),
    (16, 0x4e4f534a),
    (20 + jsonLength, bytes.length),
    (24 + jsonLength, 0x004e4942),
  ]) {
    header.setUint32(entry.$1, entry.$2, Endian.little);
  }
  output.fillRange(20, 20 + jsonLength, 0x20);
  output.setRange(20, 20 + json.length, json);
  output.setRange(28 + jsonLength, output.length, bytes.takeBytes());
  File('assets/models/deformation.glb').writeAsBytesSync(output);
}
