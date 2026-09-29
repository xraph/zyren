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
    'asset': {'version': '2.0', 'generator': 'zyren authored fixture'},
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
  final colored = jsonDecode(jsonEncode(pbr)) as Map<String, Object?>;
  final colorBytes = Uint8List.fromList([
    for (var i = 0; i < positions.length; i += 3)
      for (var c = 0; c < 3; c++) ((positions[i + c] + .5) * 255).round(),
  ]);
  final colorViews = colored['bufferViews'] as List;
  final colorAccessors = colored['accessors'] as List;
  final colorIndex = colorAccessors.length;
  colorAccessors.add({
    'bufferView': colorViews.length,
    'componentType': 5121,
    'normalized': true,
    'count': positions.length ~/ 3,
    'type': 'VEC3',
  });
  // RGB vertices need a four-byte stride in glTF.
  final paddedColors = Uint8List(positions.length ~/ 3 * 4);
  for (var i = 0; i < positions.length ~/ 3; i++) {
    paddedColors.setRange(i * 4, i * 4 + 3, colorBytes, i * 3);
  }
  colorViews.add({
    'buffer': 0,
    'byteOffset': data.length,
    'byteLength': paddedColors.length,
    'byteStride': 4,
  });
  final coloredData =
      (BytesBuilder()
            ..add(data)
            ..add(paddedColors))
          .toBytes();
  (colored['buffers'] as List).first['byteLength'] = coloredData.length;
  for (final mesh in colored['meshes'] as List) {
    for (final primitive in mesh['primitives'] as List) {
      primitive['attributes']['COLOR_0'] = colorIndex;
    }
  }
  for (final material in colored['materials'] as List) {
    material['pbrMetallicRoughness']['baseColorFactor'] = [1, 1, 1, 1];
  }
  (colored['scenes'] as List).first['name'] = 'Vertex color assembly';
  final coloredGlb = encodeGlb(colored, coloredData);
  final normalMapped = jsonDecode(jsonEncode(pbr)) as Map<String, Object?>;
  (normalMapped['materials'] as List)[1]['normalTexture'] = {'index': 0};
  normalMapped['images'] = [
    {'uri': 'data:image/png;base64,${base64Encode(ribbedNormalPng())}'},
  ];
  normalMapped['samplers'] = [
    {'minFilter': 9987, 'magFilter': 9729, 'wrapS': 10497, 'wrapT': 10497},
  ];
  (normalMapped['scenes'] as List).first['name'] = 'Normal map assembly';
  final normalGlb = encodeGlb(normalMapped, data);
  final animated = jsonDecode(jsonEncode(pbr)) as Map<String, Object?>;
  final animatedBytes = BytesBuilder()..add(data);
  int animationAccessor(
    List<double> values,
    int components, {
    bool time = false,
  }) {
    final bytes = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      bytes.setFloat32(i * 4, values[i], Endian.little);
    }
    final views = animated['bufferViews'] as List,
        accessors = animated['accessors'] as List;
    final index = accessors.length;
    accessors.add({
      'bufferView': views.length,
      'componentType': 5126,
      'count': values.length ~/ components,
      'type': components == 1 ? 'SCALAR' : 'VEC$components',
      if (time) 'min': [values.first],
      if (time) 'max': [values.last],
    });
    views.add({
      'buffer': 0,
      'byteOffset': animatedBytes.length,
      'byteLength': bytes.lengthInBytes,
    });
    animatedBytes.add(bytes.buffer.asUint8List());
    return index;
  }

  final liftTimes = animationAccessor([0, 2, 4], 1, time: true);
  final lift = animationAccessor([
    0,
    0,
    0,
    -.45,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    -.45,
    .7,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    -.45,
    0,
    0,
    0,
    0,
    0,
  ], 3);
  final spinTimes = animationAccessor([0, 1, 2, 3, 4], 1, time: true);
  final spin = animationAccessor([
    for (var i = 0; i <= 4; i++) ...[
      0.0,
      math.sin(i * math.pi / 4),
      0.0,
      math.cos(i * math.pi / 4),
    ],
  ], 4);
  final pulse = animationAccessor([.8, .8, .8, 1.1, 1.1, 1.1, .8, .8, .8], 3);
  animated['animations'] = [
    {
      'name': 'Assembly',
      'samplers': [
        {'input': liftTimes, 'output': lift, 'interpolation': 'CUBICSPLINE'},
        {'input': spinTimes, 'output': spin},
      ],
      'channels': [
        {
          'sampler': 0,
          'target': {'node': 2, 'path': 'translation'},
        },
        {
          'sampler': 1,
          'target': {'node': 3, 'path': 'rotation'},
        },
      ],
    },
    {
      'name': 'Pulse',
      'samplers': [
        {'input': liftTimes, 'output': pulse, 'interpolation': 'STEP'},
      ],
      'channels': [
        {
          'sampler': 0,
          'target': {'node': 3, 'path': 'scale'},
        },
      ],
    },
  ];
  (animated['scenes'] as List).first['name'] = 'Animated assembly';
  final animationData = animatedBytes.toBytes();
  (animated['buffers'] as List).first['byteLength'] = animationData.length;
  final animatedGlb = encodeGlb(animated, animationData);
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
    File('${location.path}/colors.glb').writeAsBytesSync(coloredGlb);
    File('${location.path}/normal-map.glb').writeAsBytesSync(normalGlb);
    File('${location.path}/animated.glb').writeAsBytesSync(animatedGlb);
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

// A tangent-space normal field for four rounded ribs. Geometry stays unchanged.
Uint8List ribbedNormalPng() {
  const size = 64;
  final rows = BytesBuilder();
  for (var y = 0; y < size; y++) {
    rows.addByte(0);
    for (var x = 0; x < size; x++) {
      final slope = -.8 * math.cos((x + .5) / size * 8 * math.pi);
      final length = math.sqrt(slope * slope + 1);
      rows.add([
        ((slope / length * .5 + .5) * 255).round(),
        128,
        ((1 / length * .5 + .5) * 255).round(),
        255,
      ]);
    }
  }
  final output = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    var crc = 0xffffffff;
    for (final byte in body) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc >>> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
      }
    }
    output.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
    output.add(body);
    output.add(
      (ByteData(4)..setUint32(0, (~crc) & 0xffffffff)).buffer.asUint8List(),
    );
  }

  chunk(
    'IHDR',
    (ByteData(13)
          ..setUint32(0, size)
          ..setUint32(4, size)
          ..setUint8(8, 8)
          ..setUint8(9, 6))
        .buffer
        .asUint8List(),
  );
  chunk('IDAT', zlib.encode(rows.toBytes()));
  chunk('IEND', []);
  return output.toBytes();
}
