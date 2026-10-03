import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';

/// Authored two-leg skin with root translation, joint animation and bind matrices.
Uint8List skinnedCharacterGltf({double legScale = 1, bool turning = false}) {
  final bytes = <int>[],
      views = <Map<String, Object>>[],
      accessors = <Map<String, Object>>[];
  int data(
    List<num> values,
    String type,
    int components, {
    bool joints = false,
  }) {
    while (bytes.length % 4 != 0) {
      bytes.add(0);
    }
    final buffer = ByteData(values.length * (joints ? 2 : 4));
    for (var i = 0; i < values.length; i++) {
      if (joints) {
        buffer.setUint16(i * 2, values[i].toInt(), Endian.little);
      } else {
        buffer.setFloat32(i * 4, values[i].toDouble(), Endian.little);
      }
    }
    views.add({
      'buffer': 0,
      'byteOffset': bytes.length,
      'byteLength': buffer.lengthInBytes,
    });
    bytes.addAll(buffer.buffer.asUint8List());
    accessors.add({
      'bufferView': views.length - 1,
      'componentType': joints ? 5123 : 5126,
      'type': type,
      'count': values.length ~/ components,
    });
    return accessors.length - 1;
  }

  final hip = .95 * legScale, shin = .45 * legScale;
  final centers = [
    Vec3.zero,
    Vec3(-.16, hip, 0),
    Vec3(-.16, hip - shin, 0),
    Vec3(-.16, hip - 2 * shin, 0),
    Vec3(.16, hip, 0),
    Vec3(.16, hip - shin, 0),
    Vec3(.16, hip - 2 * shin, 0),
    Vec3(0, hip + .2, 0),
    Vec3(0, hip + .65, 0),
  ];
  final positions = <double>[],
      normals = <double>[],
      joints = <int>[],
      weights = <double>[];
  void piece(int joint, Vec3 offset, Vec3 size) {
    final box = BoxGeometry(width: size.x, height: size.y, depth: size.z);
    for (final index in box.indices) {
      final at = Vec3.array(box.positions, index * 3) + centers[joint] + offset;
      positions.addAll(at.storage);
      normals.addAll(box.normals.sublist(index * 3, index * 3 + 3));
      joints.addAll([joint, 0, 0, 0]);
      weights.addAll([1, 0, 0, 0]);
    }
  }

  for (final joint in [1, 2, 4, 5]) {
    piece(joint, Vec3(0, -shin / 2, 0), Vec3(.18, shin, .2));
  }
  for (final joint in [3, 6]) {
    piece(joint, const Vec3(0, 0, .09), const Vec3(.2, .1, .35));
  }
  piece(7, Vec3.zero, const Vec3(.52, .5, .28));
  piece(8, Vec3.zero, const Vec3(.3, .3, .3));
  final p = data(positions, 'VEC3', 3),
      n = data(normals, 'VEC3', 3),
      j = data(joints, 'VEC4', 4, joints: true),
      w = data(weights, 'VEC4', 4);
  final encodedPositions = Float32List.fromList(positions);
  accessors[p]['min'] = [
    for (var axis = 0; axis < 3; axis++)
      [
        for (var i = axis; i < positions.length; i += 3) encodedPositions[i],
      ].reduce(math.min),
  ];
  accessors[p]['max'] = [
    for (var axis = 0; axis < 3; axis++)
      [
        for (var i = axis; i < positions.length; i += 3) encodedPositions[i],
      ].reduce(math.max),
  ];
  final bind = data(
    [
      for (final c in centers) ...[
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
        -c.x,
        -c.y,
        -c.z,
        1,
      ],
    ],
    'MAT4',
    16,
  );
  final time = data([0, .25, .5, .75, 1], 'SCALAR', 1);
  accessors[time]['min'] = [0];
  accessors[time]['max'] = [1];
  int swing(double sign) => data(
    [
      for (final a in [0.0, .35 * sign, 0.0, -.35 * sign, 0.0]) ...[
        math.sin(a / 2),
        0,
        0,
        math.cos(a / 2),
      ],
    ],
    'VEC4',
    4,
  );
  final left = swing(1),
      right = swing(-1),
      travel = data(
        [
          for (final t in [0.0, .25, .5, .75, 1.0]) ...[0, 0, t],
        ],
        'VEC3',
        3,
      );
  final turn = data(
    [
      for (final a in [
        0.0,
        math.pi / 2,
        math.pi,
        3 * math.pi / 2,
        2 * math.pi,
      ]) ...[0, math.sin(a / 2), 0, math.cos(a / 2)],
    ],
    'VEC4',
    4,
  );
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
              'baseColorFactor': [.15, .65, .88, 1],
            },
          },
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {
                  'POSITION': p,
                  'NORMAL': n,
                  'JOINTS_0': j,
                  'WEIGHTS_0': w,
                },
                'material': 0,
              },
            ],
          },
        ],
        'skins': [
          {
            'joints': List.generate(9, (i) => i),
            'inverseBindMatrices': bind,
            'skeleton': 0,
          },
        ],
        'nodes': [
          {
            'name': 'root',
            'children': [1, 4, 7, 9],
          },
          {
            'name': 'leftHip',
            'translation': centers[1].storage,
            'children': [2],
          },
          {
            'name': 'leftKnee',
            'translation': [0, -shin, 0],
            'children': [3],
          },
          {
            'name': 'leftFoot',
            'translation': [0, -shin, 0],
          },
          {
            'name': 'rightHip',
            'translation': centers[4].storage,
            'children': [5],
          },
          {
            'name': 'rightKnee',
            'translation': [0, -shin, 0],
            'children': [6],
          },
          {
            'name': 'rightFoot',
            'translation': [0, -shin, 0],
          },
          {
            'name': 'spine',
            'translation': centers[7].storage,
            'children': [8],
          },
          {
            'name': 'head',
            'translation': [0, .45, 0],
          },
          {'name': 'skin', 'mesh': 0, 'skin': 0},
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
              {'input': time, 'output': left},
              {'input': time, 'output': right},
              {'input': time, 'output': travel},
              if (turning) {'input': time, 'output': turn},
            ],
            'channels': [
              {
                'sampler': 0,
                'target': {'node': 1, 'path': 'rotation'},
              },
              {
                'sampler': 1,
                'target': {'node': 4, 'path': 'rotation'},
              },
              {
                'sampler': 2,
                'target': {'node': 0, 'path': 'translation'},
              },
              if (turning)
                {
                  'sampler': 3,
                  'target': {'node': 0, 'path': 'rotation'},
                },
            ],
          },
        ],
      }),
    ),
  );
}

final class SkinnedCharacterSource implements ByteSourceResolver {
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    return ResolvedSource(
      effectiveUri: uri,
      bytes: skinnedCharacterGltf(
        legScale: uri.path.contains('tall') ? 1.3 : 1,
        turning: uri.path.contains('turn'),
      ),
    );
  }
}
