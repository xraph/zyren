import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'model_test.dart' show load;
import 'support/fixtures.dart';

Uint8List featureModel({
  List<double> ids = const [0, 0, 0, 1, 1, 1],
  bool legacy = false,
  List<Map<String, Object?>>? sets,
  Map<String, Object?> changes = const {},
  Map<String, Object?> feature = const {'featureCount': 2, 'attribute': 0},
}) {
  final positions = [
    -2.0,
    -1.0,
    0.0,
    0.0,
    -1.0,
    0.0,
    -1.0,
    1.0,
    0.0,
    0.0,
    -1.0,
    0.0,
    2.0,
    -1.0,
    0.0,
    1.0,
    1.0,
    0.0,
  ];
  final binary = ByteData(96);
  for (var i = 0; i < positions.length; i++) {
    binary.setFloat32(i * 4, positions[i], Endian.little);
  }
  for (var i = 0; i < ids.length; i++) {
    binary.setFloat32(72 + i * 4, ids[i], Endian.little);
  }
  return glb({
    'asset': {'version': '2.0'},
    'extensionsUsed': ['KHR_materials_unlit', if (!legacy) 'EXT_mesh_features'],
    'buffers': [
      {'byteLength': 96},
    ],
    'bufferViews': [
      {'buffer': 0, 'byteLength': 72},
      {'buffer': 0, 'byteOffset': 72, 'byteLength': 24},
    ],
    'accessors': [
      {
        'bufferView': 0,
        'componentType': 5126,
        'type': 'VEC3',
        'count': 6,
        'min': [-2, -1, 0],
        'max': [2, 1, 0],
      },
      {'bufferView': 1, 'componentType': 5126, 'type': 'SCALAR', 'count': 6},
    ],
    'materials': [
      {
        'extensions': {'KHR_materials_unlit': <String, Object?>{}},
      },
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {
              'POSITION': 0,
              legacy ? '_BATCHID' : '_FEATURE_ID_0': 1,
            },
            'material': 0,
            if (!legacy)
              'extensions': {
                'EXT_mesh_features': {
                  'featureIds': sets ?? [feature],
                },
              },
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
  }, binary: binary.buffer.asUint8List());
}

void main() {
  test('multiple sets retain stable identity on each partition', () async {
    final model = await load(
      featureModel(
        sets: [
          {'featureCount': 2, 'attribute': 0, 'label': 'buildings'},
          {'featureCount': 2, 'attribute': 0, 'label': 'components'},
        ],
      ),
    );
    final mesh = model.instantiate().children.single.children.last as ModelMesh;
    expect(mesh.features.map((f) => f.setIndex), [0, 1]);
    expect(mesh.features.map((f) => f.label), ['buildings', 'components']);
    expect(mesh.features.map((f) => f.id), [1, 1]);
  });
  test(
    'repeated instances include partition counts in scene admission',
    () async {
      await expectLater(
        load(
          featureModel(
            changes: {
              'nodes': [
                {'mesh': 0},
                {'mesh': 0},
              ],
              'scenes': [
                {
                  'nodes': [0, 1],
                },
              ],
            },
          ),
          options: const GltfOptions(limits: GltfLimits(maxPrimitives: 3)),
        ),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
    },
  );
  test('labels and null features survive scoped instantiation', () async {
    final model = await load(
      featureModel(
        feature: {
          'featureCount': 1,
          'attribute': 0,
          'nullFeatureId': 1,
          'label': 'building',
        },
      ),
    );
    final meshes = model
        .instantiate()
        .children
        .single
        .children
        .cast<ModelMesh>()
        .toList();
    expect(meshes.first.features.single.label, 'building');
    expect(meshes.last.features.single.id, isNull);
  });
  test(
    'unknown feature textures and missing attributes fail explicitly',
    () async {
      for (final feature in [
        {'featureCount': 2, 'attribute': 2147483647},
        {
          'featureCount': 2,
          'texture': {'index': 0},
        },
        {'featureCount': 2, 'attribute': 0, 'label': 'not a label'},
      ]) {
        await expectLater(
          load(featureModel(feature: feature)),
          throwsA(isA<AssetLoadException>()),
        );
      }
    },
  );
  test(
    'feature partitions preserve compact geometry through flat normals',
    () async {
      for (final legacy in [false, true]) {
        final model = await load(featureModel(legacy: legacy));
        final meshes = model
            .instantiate()
            .children
            .single
            .children
            .cast<Mesh>()
            .toList();
        expect(meshes, hasLength(2));
        final first = meshes.first as ModelMesh,
            last = meshes.last as ModelMesh;
        expect(first.features.single.id, 0);
        expect(last.features.single.id, 1);
        expect(last.features.single.legacyBatch, legacy);
        expect(() => last.features.clear(), throwsUnsupportedError);
        final other =
            model.instantiate().children.single.children.last as ModelMesh;
        expect(other.geometry, same(last.geometry));
        first.visible = false;
        expect(other.visible, isTrue);
        expect(meshes.map((m) => m.geometry.vertexCount), [3, 3]);
        expect(meshes.first.geometry.positions, [
          -2,
          -1,
          0,
          0,
          -1,
          0,
          -1,
          1,
          0,
        ]);
        expect(meshes.last.geometry.positions, [0, -1, 0, 2, -1, 0, 1, 1, 0]);
      }
    },
  );
  test(
    'fractional IDs and mixed triangle classification cannot be discarded',
    () async {
      for (final ids in <List<double>>[
        [0.0, 0, 0, 1.5, 1.5, 1.5],
        [0.0, 1, 0, 1, 1, 1],
      ]) {
        await expectLater(
          load(featureModel(ids: ids)),
          throwsA(isA<AssetLoadException>()),
        );
      }
    },
  );
  test('feature draw calls count against primitive limits', () async {
    await expectLater(
      load(
        featureModel(),
        options: const GltfOptions(limits: GltfLimits(maxPrimitives: 1)),
      ),
      throwsA(
        isA<AssetLoadException>().having(
          (e) => e.code,
          'code',
          AssetLoadError.limitExceeded,
        ),
      ),
    );
  });
}
