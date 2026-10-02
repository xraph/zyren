import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'model_test.dart' show load;
import 'features_test.dart' show featureModel;
import 'support/fixtures.dart';

Uint8List metadataModel({
  Map<String, Object?>? property,
  List<int>? offsets,
  bool missing = false,
  int declaredLength = 48,
}) {
  final binary = ByteData(48);
  binary.setFloat32(0, 12.5, Endian.little);
  binary.setFloat32(4, 40, Endian.little);
  final text = utf8.encode('NorthSouth');
  binary.buffer.asUint8List().setRange(8, 18, text);
  for (var i = 0; i < 3; i++) {
    binary.setUint32(20 + i * 4, (offsets ?? [0, 5, 10])[i], Endian.little);
  }
  binary.setUint8(32, 1);
  binary.setUint8(36, 0);
  binary.setUint8(37, 255);
  return glb({
    'asset': {'version': '2.0'},
    'extensionsUsed': ['EXT_structural_metadata'],
    'buffers': [
      {'byteLength': declaredLength},
    ],
    'bufferViews': [
      {'buffer': 0, 'byteLength': 8},
      {'buffer': 0, 'byteOffset': 8, 'byteLength': 10},
      {'buffer': 0, 'byteOffset': 20, 'byteLength': 12},
      {'buffer': 0, 'byteOffset': 32, 'byteLength': 1},
      {'buffer': 0, 'byteOffset': 36, 'byteLength': 2},
    ],
    'extensions': {
      'EXT_structural_metadata': {
        'schema': {
          'id': 'buildings',
          'classes': {
            'building': {
              'properties': {
                'height':
                    property ??
                    {
                      'type': 'SCALAR',
                      'componentType': 'FLOAT32',
                      'required': true,
                    },
                'name': {'type': 'STRING'},
                'occupied': {'type': 'BOOLEAN'},
                'quality': {
                  'type': 'SCALAR',
                  'componentType': 'UINT8',
                  'normalized': true,
                  'scale': 10,
                  'offset': 5,
                },
                'owner': {'type': 'STRING', 'default': 'Unknown'},
              },
            },
          },
        },
        'propertyTables': [
          {
            'class': 'building',
            'count': 2,
            'properties': {
              if (!missing) 'height': {'values': 0},
              'name': {'values': 1, 'stringOffsets': 2},
              'occupied': {'values': 3},
              'quality': {'values': 4},
            },
          },
        ],
      },
    },
  }, binary: binary.buffer.asUint8List());
}

Uint8List metadataFeatureModel() {
  (Map<String, Object?>, Uint8List) unpack(Uint8List bytes) {
    final data = ByteData.sublistView(bytes),
        jsonLength = ByteData.sublistView(bytes).getUint32(12, Endian.little);
    final root =
        jsonDecode(utf8.decode(bytes.sublist(20, 20 + jsonLength)))
            as Map<String, Object?>;
    final length = data.getUint32(20 + jsonLength, Endian.little);
    return (
      root,
      Uint8List.sublistView(bytes, 28 + jsonLength, 28 + jsonLength + length),
    );
  }

  final (root, geometry) = unpack(
    featureModel(
      feature: {'featureCount': 2, 'attribute': 0, 'propertyTable': 0},
    ),
  );
  final (metadata, values) = unpack(metadataModel());
  final views = root['bufferViews'] as List;
  final shift = views.length;
  for (final dynamic view in metadata['bufferViews'] as List) {
    views.add({
      ...view as Map<String, Object?>,
      'byteOffset': geometry.length + ((view['byteOffset'] as int?) ?? 0),
    });
  }
  root['buffers'] = [
    {'byteLength': geometry.length + values.length},
  ];
  (root['extensionsUsed'] as List).add('EXT_structural_metadata');
  root['extensions'] = metadata['extensions'];
  final extension =
      (root['extensions'] as Map)['EXT_structural_metadata'] as Map;
  for (final dynamic table in extension['propertyTables'] as List) {
    for (final dynamic property in (table['properties'] as Map).values) {
      property['values'] = (property['values'] as int) + shift;
      if (property.containsKey('stringOffsets') as bool) {
        property['stringOffsets'] = (property['stringOffsets'] as int) + shift;
      }
    }
  }
  return glb(root, binary: [...geometry, ...values]);
}

void main() {
  test('metadata GLB accepts seven bytes of zero binary padding', () async {
    expect(
      (await load(
        metadataModel(declaredLength: 41),
      )).propertyTables.single.count,
      2,
    );
  });
  test('vectors and enums retain their declared values', () async {
    final bytes = ByteData(12);
    for (var i = 0; i < 4; i++) {
      bytes.setInt16(i * 2, i - 2, Endian.little);
    }
    bytes.setUint8(8, 1);
    bytes.setUint8(9, 2);
    final model = await load(
      glb({
        'asset': {'version': '2.0'},
        'extensionsUsed': ['EXT_structural_metadata'],
        'buffers': [
          {'byteLength': 12},
        ],
        'bufferViews': [
          {'buffer': 0, 'byteLength': 8},
          {'buffer': 0, 'byteOffset': 8, 'byteLength': 2},
        ],
        'extensions': {
          'EXT_structural_metadata': {
            'schema': {
              'classes': {
                'component': {
                  'properties': {
                    'vector': {'type': 'VEC2', 'componentType': 'INT16'},
                    'kind': {'type': 'ENUM', 'enumType': 'kind'},
                  },
                },
              },
              'enums': {
                'kind': {
                  'valueType': 'UINT8',
                  'values': [
                    {'name': 'Wall', 'value': 1},
                    {'name': 'Roof', 'value': 2},
                  ],
                },
              },
            },
            'propertyTables': [
              {
                'class': 'component',
                'count': 2,
                'properties': {
                  'vector': {'values': 0},
                  'kind': {'values': 1},
                },
              },
            ],
          },
        },
      }, binary: bytes.buffer.asUint8List()),
    );
    expect(model.propertyTables.single.properties(0), {
      'vector': [-2, -1],
      'kind': 'Wall',
    });
    expect(model.propertyTables.single.properties(1), {
      'vector': [0, 1],
      'kind': 'Roof',
    });
    expect(
      () =>
          (model.propertyTables.single.properties(1)['vector'] as List).clear(),
      throwsUnsupportedError,
    );
  });
  test('noData resolves to the declared final default', () async {
    final model = await load(
      metadataModel(
        property: {
          'type': 'SCALAR',
          'componentType': 'FLOAT32',
          'noData': 40,
          'default': 99,
        },
      ),
    );
    expect(model.propertyTables.single.properties(1)['height'], 99);
    expect(model.propertyTables.single.properties(0)['height'], 12.5);
  });
  test('feature table references retain row data after loading', () async {
    final model = await load(metadataFeatureModel());
    expect(model.propertyTables.single.properties(1)['name'], 'South');
    expect(model.issues, isEmpty);
  });
  test(
    'unsupported metadata profiles fail without dropping properties',
    () async {
      for (final property in [
        {'type': 'SCALAR', 'componentType': 'FLOAT32', 'array': true},
        {'type': 'SCALAR', 'componentType': 'UINT64'},
        {'type': 'STRING', 'normalized': true},
      ]) {
        await expectLater(
          load(metadataModel(property: property)),
          throwsA(isA<AssetLoadException>()),
        );
      }
    },
  );
  test(
    'structural tables retain typed values, defaults and transforms',
    () async {
      final model = await load(metadataModel());
      final tables = model.propertyTables;
      final row = tables.single.properties(1);
      expect(row, {
        'height': 40,
        'name': 'South',
        'occupied': false,
        'quality': 15,
        'owner': 'Unknown',
      });
      expect(tables.single.properties(0)['quality'], 5);
      expect(() => row['name'] = 'Changed', throwsUnsupportedError);
    },
  );
  test('bad offsets and omitted required values fail', () async {
    for (final bytes in [
      metadataModel(offsets: [0, 8, 4]),
      metadataModel(missing: true),
    ]) {
      await expectLater(load(bytes), throwsA(isA<AssetLoadException>()));
    }
  });
}
