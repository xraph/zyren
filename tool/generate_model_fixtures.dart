import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

// Authored test geometry and the repository's four-corner PNG. No external model.
void main() {
  final positions = <double>[],
      normals = <double>[],
      uv = <double>[],
      indices = <int>[];
  for (final (normal, face) in <(List<double>, List<double>)>[
    ([0, 0, 1], [-.5, -.5, .5, .5, -.5, .5, .5, .5, .5, -.5, .5, .5]),
    ([0, 0, -1], [.5, -.5, -.5, -.5, -.5, -.5, -.5, .5, -.5, .5, .5, -.5]),
    ([1, 0, 0], [.5, -.5, .5, .5, -.5, -.5, .5, .5, -.5, .5, .5, .5]),
    ([-1, 0, 0], [-.5, -.5, -.5, -.5, -.5, .5, -.5, .5, .5, -.5, .5, -.5]),
    ([0, 1, 0], [-.5, .5, .5, .5, .5, .5, .5, .5, -.5, -.5, .5, -.5]),
    ([0, -1, 0], [-.5, -.5, -.5, .5, -.5, -.5, .5, -.5, .5, -.5, -.5, .5]),
  ]) {
    final first = positions.length ~/ 3;
    positions.addAll(face);
    for (var i = 0; i < 4; i++) {
      normals.addAll(normal);
    }
    uv.addAll([0, 1, 1, 1, 1, 0, 0, 0]);
    indices.addAll([first, first + 1, first + 2, first, first + 2, first + 3]);
  }
  final binary = BytesBuilder(),
      views = <Map<String, Object?>>[],
      accessors = <Map<String, Object?>>[];
  for (final (values, size) in [(positions, 3), (normals, 3), (uv, 2)]) {
    final bytes = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      bytes.setFloat32(i * 4, values[i], Endian.little);
    }
    views.add({
      'buffer': 0,
      'byteOffset': binary.length,
      'byteLength': bytes.lengthInBytes,
    });
    binary.add(bytes.buffer.asUint8List());
    accessors.add({
      'bufferView': views.length - 1,
      'componentType': 5126,
      'count': 24,
      'type': 'VEC$size',
      if (accessors.isEmpty) 'min': [-.5, -.5, -.5],
      if (accessors.isEmpty) 'max': [.5, .5, .5],
    });
  }
  final indexBytes = ByteData(indices.length * 2);
  for (var i = 0; i < indices.length; i++) {
    indexBytes.setUint16(i * 2, indices[i], Endian.little);
  }
  views.add({
    'buffer': 0,
    'byteOffset': binary.length,
    'byteLength': indexBytes.lengthInBytes,
    'target': 34963,
  });
  binary.add(indexBytes.buffer.asUint8List());
  accessors.add({
    'bufferView': 3,
    'componentType': 5123,
    'count': indices.length,
    'type': 'SCALAR',
  });
  const png =
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAHUlEQVR4AQESAO3/AP8AAIAA/wD/AAAA/wD/////PdsIeTLV3/QAAAAASUVORK5CYII=';
  final root = <String, Object?>{
    'asset': {'version': '2.0', 'generator': 'gpu3d authored fixture'},
    'extensionsUsed': ['KHR_materials_unlit'],
    'extensionsRequired': ['KHR_materials_unlit'],
    'buffers': [
      {'byteLength': binary.length},
    ],
    'bufferViews': views,
    'accessors': accessors,
    'materials': [
      {
        'name': 'Corner colors',
        'extensions': {'KHR_materials_unlit': <String, Object?>{}},
        'pbrMetallicRoughness': {
          'baseColorTexture': {'index': 0},
        },
      },
    ],
    'images': [
      {'uri': 'data:image/png;base64,$png'},
    ],
    'textures': [
      {'source': 0, 'sampler': 0},
    ],
    'samplers': [
      {'minFilter': 9987, 'magFilter': 9728, 'wrapS': 33071, 'wrapT': 33071},
    ],
    'meshes': [
      {
        'name': 'Textured box',
        'primitives': [
          {
            'attributes': {'POSITION': 0, 'NORMAL': 1, 'TEXCOORD_0': 2},
            'indices': 3,
            'material': 0,
          },
        ],
      },
    ],
    'nodes': [
      {
        'name': 'Assembly',
        'children': [1, 2, 3],
      },
      {
        'name': 'Base',
        'mesh': 0,
        'translation': [0, -.7, 0],
        'scale': [2.4, .25, 1.4],
      },
      {
        'name': 'Housing',
        'mesh': 0,
        'translation': [-.45, 0, 0],
        'scale': [1.2, 1.2, 1.2],
      },
      {
        'name': 'Motor',
        'mesh': 0,
        'translation': [.8, -.1, 0],
        'scale': [.8, .8, .8],
      },
      {'name': 'Single box', 'mesh': 0},
    ],
    'scenes': [
      {
        'name': 'Assembly',
        'nodes': [0],
      },
      {
        'name': 'Single box',
        'nodes': [4],
      },
    ],
    'scene': 0,
  };
  final data = binary.toBytes();
  final glb = encodeGlb(root, data);
  final pbr = jsonDecode(jsonEncode(root)) as Map<String, Object?>;
  pbr['extensionsUsed'] = ['KHR_lights_punctual'];
  pbr['extensionsRequired'] = ['KHR_lights_punctual'];
  pbr['extensions'] = {
    'KHR_lights_punctual': {
      'lights': [
        {
          'name': 'Key',
          'type': 'point',
          'color': [1, .92, .82],
          'intensity': 90,
        },
        {
          'name': 'Fill',
          'type': 'directional',
          'color': [.55, .7, 1],
          'intensity': 1.5,
        },
      ],
    },
  };
  pbr['materials'] = [
    {
      'name': 'Brushed base',
      'pbrMetallicRoughness': {
        'baseColorFactor': [.4, .45, .5, 1],
        'metallicFactor': .8,
        'roughnessFactor': .5,
      },
    },
    {
      'name': 'Painted housing',
      'pbrMetallicRoughness': {
        'baseColorFactor': [.025, .35, .3, 1],
        'metallicFactor': 0,
        'roughnessFactor': .4,
      },
    },
    {
      'name': 'Copper motor',
      'pbrMetallicRoughness': {
        'baseColorFactor': [.95, .64, .54, 1],
        'metallicFactor': 1,
        'roughnessFactor': .25,
      },
    },
  ];
  final baseMesh = (pbr['meshes'] as List).single;
  pbr['meshes'] = [
    for (var i = 0; i < 3; i++)
      {
        ...baseMesh,
        'primitives': [
          {...(baseMesh['primitives'] as List).single, 'material': i},
        ],
      },
  ];
  final pbrNodes = pbr['nodes'] as List;
  pbrNodes[0]['name'] = 'PBR assembly';
  for (var i = 1; i <= 3; i++) {
    pbrNodes[i]['mesh'] = i - 1;
  }
  pbrNodes.addAll([
    {
      'name': 'Key light',
      'translation': [2, 4, 4],
      'extensions': {
        'KHR_lights_punctual': {'light': 0},
      },
    },
    {
      'name': 'Fill light',
      'rotation': [-math.sin(.25), 0, 0, math.cos(.25)],
      'extensions': {
        'KHR_lights_punctual': {'light': 1},
      },
    },
  ]);
  pbr['scenes'] = [
    {
      'name': 'PBR assembly',
      'nodes': [0, 5, 6],
    },
    {
      'name': 'No authored lights',
      'nodes': [0],
    },
  ];
  // The second scene has PBR surfaces but no authored lights, for viewer fill.
  final pbrGlb = encodeGlb(pbr, data);
  root['buffers'] = [
    <String, Object?>{'byteLength': data.length, 'uri': 'assembly.bin'},
  ];
  (root['images'] as List).first['uri'] = 'corners.png';
  for (final directory in [
    '../test_assets/gltf/',
    '../examples/model_viewer/assets/models/',
  ]) {
    final location = Directory.fromUri(Platform.script.resolve(directory))
      ..createSync(recursive: true);
    File('${location.path}/assembly.glb').writeAsBytesSync(glb);
    File('${location.path}/pbr.glb').writeAsBytesSync(pbrGlb);
    File('${location.path}/assembly.gltf').writeAsStringSync(
      "${const JsonEncoder.withIndent('  ').convert(root)}\n",
    );
    File('${location.path}/assembly.bin').writeAsBytesSync(data);
    File('${location.path}/corners.png').writeAsBytesSync(base64Decode(png));
  }
}

Uint8List encodeGlb(Map<String, Object?> root, Uint8List data) {
  final json = utf8.encode(jsonEncode(root)), padded = (json.length + 3) & ~3;
  final result = Uint8List(28 + padded + data.length);
  final header = ByteData.sublistView(result);
  for (final (offset, value) in [
    (0, 0x46546c67),
    (4, 2),
    (8, result.length),
    (12, padded),
    (16, 0x4e4f534a),
    (20 + padded, data.length),
    (24 + padded, 0x004e4942),
  ]) {
    header.setUint32(offset, value, Endian.little);
  }
  result.fillRange(20, 20 + padded, 32);
  result.setRange(20, 20 + json.length, json);
  result.setRange(28 + padded, result.length, data);
  return result;
}
