import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';

/// A self-contained glTF robot with two animated hip pivots, in metres.
/// This authored fixture has rigid limbs. Skinned-rig qualification is separate.
Uint8List characterGltf() {
  final bytes = <int>[],
      views = <Map<String, Object>>[],
      accessors = <Map<String, Object>>[];
  int floats(
    List<double> values,
    String type,
    int count, {
    List<double>? min,
    List<double>? max,
  }) {
    final data = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      data.setFloat32(i * 4, values[i], Endian.little);
    }
    views.add({
      'buffer': 0,
      'byteOffset': bytes.length,
      'byteLength': data.lengthInBytes,
    });
    bytes.addAll(data.buffer.asUint8List());
    accessors.add({
      'bufferView': views.length - 1,
      'componentType': 5126,
      'count': count,
      'type': type,
      'min': ?min,
      'max': ?max,
    });
    return accessors.length - 1;
  }

  final box = BoxGeometry();
  final positions = [
    for (final i in box.indices) ...box.positions.sublist(i * 3, i * 3 + 3),
  ];
  final normals = [
    for (final i in box.indices) ...box.normals.sublist(i * 3, i * 3 + 3),
  ];
  final p = floats(
    positions,
    'VEC3',
    positions.length ~/ 3,
    min: [-.5, -.5, -.5],
    max: [.5, .5, .5],
  );
  final n = floats(normals, 'VEC3', normals.length ~/ 3);
  final times = floats([0, .25, .5, .75, 1], 'SCALAR', 5, min: [0], max: [1]);
  int rotations(double sign) => floats(
    [
      for (final angle in [0.0, .6 * sign, 0.0, -.6 * sign, 0.0]) ...[
        math.sin(angle / 2),
        0.0,
        0.0,
        math.cos(angle / 2),
      ],
    ],
    'VEC4',
    5,
  );
  final left = rotations(1), right = rotations(-1);
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'asset': {'version': '2.0'},
        'extensionsUsed': ['KHR_materials_unlit'],
        'buffers': [
          {
            'byteLength': bytes.length,
            'uri':
                'data:application/octet-stream;base64,${base64Encode(bytes)}',
          },
        ],
        'bufferViews': views,
        'accessors': accessors,
        'materials': [
          {
            'extensions': {'KHR_materials_unlit': <String, Object>{}},
            'pbrMetallicRoughness': {
              'baseColorFactor': [.2, .65, .95, 1],
            },
          },
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': p, 'NORMAL': n},
                'material': 0,
              },
            ],
          },
        ],
        'nodes': [
          {
            'name': 'robot',
            'children': [1, 2, 3, 5],
          },
          {
            'name': 'torso',
            'mesh': 0,
            'translation': [0, .35, 0],
            'scale': [.5, .6, .25],
          },
          {
            'name': 'head',
            'mesh': 0,
            'translation': [0, .85, 0],
            'scale': [.3, .3, .3],
          },
          {
            'name': 'left-hip',
            'translation': [-.16, 0, 0],
            'children': [4],
          },
          {
            'name': 'left-leg',
            'mesh': 0,
            'translation': [0, -.35, 0],
            'scale': [.18, .7, .18],
          },
          {
            'name': 'right-hip',
            'translation': [.16, 0, 0],
            'children': [6],
          },
          {
            'name': 'right-leg',
            'mesh': 0,
            'translation': [0, -.35, 0],
            'scale': [.18, .7, .18],
          },
        ],
        'scenes': [
          {
            'nodes': [0],
          },
        ],
        'scene': 0,
        'animations': [
          {
            'name': 'walk',
            'samplers': [
              {'input': times, 'output': left},
              {'input': times, 'output': right},
            ],
            'channels': [
              {
                'sampler': 0,
                'target': {'node': 3, 'path': 'rotation'},
              },
              {
                'sampler': 1,
                'target': {'node': 5, 'path': 'rotation'},
              },
            ],
          },
        ],
      }),
    ),
  );
}

final class CharacterAssetSource implements ByteSourceResolver {
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    if (uri != Uri.parse('asset:///character.gltf')) {
      throw ArgumentError('Unknown character asset.');
    }
    return ResolvedSource(effectiveUri: uri, bytes: characterGltf());
  }
}
