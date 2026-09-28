import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;

Uint8List glb(
  Map<String, Object?> root, {
  List<int>? binary,
  List<int>? unknown,
}) {
  final json = utf8.encode(jsonEncode(root));
  final jsonLength = (json.length + 3) & ~3;
  final binLength = binary == null ? 0 : (binary.length + 3) & ~3;
  final extraLength = unknown == null ? 0 : (unknown.length + 3) & ~3;
  final bytes = Uint8List(
    20 +
        jsonLength +
        (binary == null ? 0 : 8 + binLength) +
        (unknown == null ? 0 : 8 + extraLength),
  );
  final data = ByteData.sublistView(bytes);
  for (final (offset, value) in [
    (0, 0x46546c67),
    (4, 2),
    (8, bytes.length),
    (12, jsonLength),
    (16, 0x4e4f534a),
  ]) {
    data.setUint32(offset, value, Endian.little);
  }
  bytes.fillRange(20, 20 + jsonLength, 0x20);
  bytes.setRange(20, 20 + json.length, json);
  var offset = 20 + jsonLength;
  for (final (chunk, length, type) in [
    (binary, binLength, 0x004e4942),
    (unknown, extraLength, 42),
  ]) {
    if (chunk == null) continue;
    data.setUint32(offset, length, Endian.little);
    data.setUint32(offset + 4, type, Endian.little);
    bytes.setRange(offset + 8, offset + 8 + chunk.length, chunk);
    offset += 8 + length;
  }
  return bytes;
}

Uint8List triangleModel({bool unlit = true, Map<String, Object?>? changes}) {
  final positions = ByteData(36);
  final values = [-1.0, -1.0, 0.0, 1.0, -1.0, 0.0, 0.0, 1.0, 0.0];
  for (var i = 0; i < values.length; i++) {
    positions.setFloat32(i * 4, values[i], Endian.little);
  }
  return glb({
    'asset': {'version': '2.0'},
    if (unlit) 'extensionsUsed': ['KHR_materials_unlit'],
    if (unlit) 'extensionsRequired': ['KHR_materials_unlit'],
    'buffers': [
      {'byteLength': 36},
    ],
    'bufferViews': [
      {'buffer': 0, 'byteLength': 36},
    ],
    'accessors': [
      {
        'bufferView': 0,
        'componentType': 5126,
        'count': 3,
        'type': 'VEC3',
        'min': [-1, -1, 0],
        'max': [1, 1, 0],
      },
    ],
    'materials': [
      {
        'pbrMetallicRoughness': {
          'baseColorFactor': [1, 0, 0, 1],
        },
        if (unlit) 'extensions': {'KHR_materials_unlit': <String, Object?>{}},
      },
    ],
    'meshes': [
      {
        'name': 'triangle',
        'primitives': [
          {
            'attributes': {'POSITION': 0},
            'material': 0,
          },
        ],
      },
    ],
    'nodes': [
      {
        'name': 'parent',
        'translation': [1, 2, 3],
        'children': [1],
      },
      {'name': 'triangle', 'mesh': 0},
    ],
    'scenes': [
      {
        'name': 'Scene',
        'nodes': [0],
      },
    ],
    'scene': 0,
    ...?changes,
  }, binary: positions.buffer.asUint8List());
}

Uint8List primitiveModel({
  List<double> positions = const [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0],
  List<double>? normals,
  List<int>? indices,
  int mode = 4,
  bool byteUvs = false,
  Map<String, Object?> primitiveChanges = const {},
  Map<String, Object?> changes = const {},
}) {
  final binary = BytesBuilder(),
      views = <Map<String, Object?>>[],
      accessors = <Map<String, Object?>>[];
  final attributes = <String, Object?>{};
  void attribute(String name, List<double> values, int size) {
    final data = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      data.setFloat32(i * 4, values[i], Endian.little);
    }
    final view = views.length;
    views.add({
      'buffer': 0,
      'byteOffset': binary.length,
      'byteLength': data.lengthInBytes,
    });
    binary.add(data.buffer.asUint8List());
    attributes[name] = accessors.length;
    accessors.add({
      'bufferView': view,
      'componentType': 5126,
      'count': values.length ~/ size,
      'type': 'VEC$size',
      if (name == 'POSITION')
        'min': [
          for (var c = 0; c < 3; c++)
            [
              for (var i = c; i < values.length; i += 3) values[i],
            ].reduce(math.min),
        ],
      if (name == 'POSITION')
        'max': [
          for (var c = 0; c < 3; c++)
            [
              for (var i = c; i < values.length; i += 3) values[i],
            ].reduce(math.max),
        ],
    });
  }

  attribute('POSITION', positions, 3);
  if (normals != null) attribute('NORMAL', normals, 3);
  if (byteUvs) {
    final view = views.length, count = positions.length ~/ 3;
    views.add({
      'buffer': 0,
      'byteOffset': binary.length,
      'byteLength': count * 4,
      'byteStride': 4,
    });
    attributes['TEXCOORD_0'] = accessors.length;
    accessors.add({
      'bufferView': view,
      'componentType': 5121,
      'normalized': true,
      'count': count,
      'type': 'VEC2',
    });
    for (var i = 0; i < count; i++) {
      binary.add([i == 1 || i == 2 ? 255 : 0, i < 2 ? 255 : 0, 0, 0]);
    }
  }
  int? indexAccessor;
  if (indices != null) {
    final view = views.length, data = ByteData(indices.length * 2);
    for (var i = 0; i < indices.length; i++) {
      data.setUint16(i * 2, indices[i], Endian.little);
    }
    views.add({
      'buffer': 0,
      'byteOffset': binary.length,
      'byteLength': data.lengthInBytes,
      'target': 34963,
    });
    indexAccessor = accessors.length;
    accessors.add({
      'bufferView': view,
      'componentType': 5123,
      'count': indices.length,
      'type': 'SCALAR',
    });
    binary.add(data.buffer.asUint8List());
  }
  final bytes = binary.toBytes();
  return glb({
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
      },
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': attributes,
            'material': 0,
            'mode': mode,
            'indices': ?indexAccessor,
            ...primitiveChanges,
          },
        ],
      },
    ],
    'nodes': [
      {'mesh': 0},
    ],
    'scenes': [
      {
        'nodes': [0],
      },
    ],
    ...changes,
  }, binary: bytes);
}

const cornersPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAHUlEQVR4AQESAO3/AP8AAIAA/wD/AAAA/wD/////PdsIeTLV3/QAAAAASUVORK5CYII=';

Uint8List texturedModel({
  String? imageUri,
  String? mimeType,
  int minFilter = 9728,
  List<Object?>? materials,
  Map<String, Object?> changes = const {},
}) => primitiveModel(
  indices: [0, 1, 2, 0, 2, 3],
  byteUvs: true,
  normals: [
    for (var i = 0; i < 4; i++) ...[0, 0, 1],
  ],
  changes: {
    'materials':
        materials ??
        [
          {
            'extensions': {'KHR_materials_unlit': <String, Object?>{}},
            'pbrMetallicRoughness': {
              'baseColorTexture': {'index': 0},
            },
          },
        ],
    'textures': [
      {'source': 0, 'sampler': 0},
    ],
    'images': [
      {
        'uri': imageUri ?? 'data:image/png;base64,$cornersPng',
        'mimeType': ?mimeType,
      },
    ],
    'samplers': [
      {
        'minFilter': minFilter,
        'magFilter': 9728,
        'wrapS': 33071,
        'wrapT': 33648,
      },
    ],
    ...changes,
  },
);

Uint8List editModel(
  Uint8List bytes,
  void Function(Map<String, Object?>) edit, {
  Uint8List? appendBinary,
}) {
  final header = ByteData.sublistView(bytes);
  final jsonLength = header.getUint32(12, Endian.little);
  final root =
      jsonDecode(utf8.decode(bytes.sublist(20, 20 + jsonLength)))
          as Map<String, Object?>;
  final binaryOffset = 20 + jsonLength + 8;
  final binary = BytesBuilder()..add(bytes.sublist(binaryOffset));
  if (appendBinary != null) binary.add(appendBinary);
  edit(root);
  if (appendBinary != null) {
    (root['buffers'] as List).first['byteLength'] = binary.length;
  }
  return glb(root, binary: binary.toBytes());
}
