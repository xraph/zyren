import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'support/fixtures.dart';
import 'model_test.dart' show Sources;

const extension = 'KHR_draco_mesh_compression';
Map<String, Object?> document({int mode = 4}) => {
  'asset': {'version': '2.0'},
  'extensionsUsed': [extension],
  'extensionsRequired': [extension],
  'buffers': [
    {'byteLength': 1},
  ],
  'bufferViews': [
    {'buffer': 0, 'byteLength': 1},
  ],
  'accessors': [
    {
      'componentType': 5126,
      'count': 4,
      'type': 'VEC3',
      'min': [-1, -1, 0],
      'max': [1, 1, 0],
    },
    {'componentType': 5123, 'count': mode == 5 ? 4 : 6, 'type': 'SCALAR'},
  ],
  'meshes': [
    {
      'primitives': [
        {
          'attributes': {'POSITION': 0},
          'indices': 1,
          'mode': mode,
          'extensions': {
            extension: {
              'bufferView': 0,
              'attributes': {'POSITION': 77},
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
  'scene': 0,
};
Map<String, Object?> accessor(Map<String, Object?> root, int i) =>
    (root['accessors'] as List)[i] as Map<String, Object?>;
Map<String, Object?> primitive(Map<String, Object?> root) =>
    ((root['meshes'] as List).single as Map)['primitives'][0]
        as Map<String, Object?>;

class Decoder implements CompressedMeshDecoder {
  int calls = 0;
  @override
  Set<MeshEncoding> get encodings => {MeshEncoding.draco};
  @override
  Future<DecodedMeshData> decode(
    Uint8List bytes, {
    required MeshEncoding encoding,
    MeshDecodeLimits limits = const MeshDecodeLimits(),
  }) async {
    calls++;
    expect(bytes, [42]);
    return DecodedMeshData(
      vertexCount: 4,
      indices: Uint32List.fromList([0, 1, 2, 0, 2, 3]),
      attributes: [
        MeshAttributeData(
          id: 77,
          type: MeshScalarType.float32,
          components: 3,
          bytes: Float32List.fromList([
            -1,
            -1,
            0,
            1,
            -1,
            0,
            1,
            1,
            0,
            -1,
            1,
            0,
          ]).buffer.asUint8List(),
        ),
      ],
    );
  }
}

Future<ModelAsset> loadBytes(Uint8List bytes, {Decoder? decoder}) async {
  final scope = AssetScope(
    services: AssetServices(resolver: Sources(bytes), meshDecoder: decoder),
  );
  addTearDown(scope.close);
  return scope.load(Gltf.asset('model.glb')).result;
}

Future<ModelAsset> load(Map<String, Object?> root, {Decoder? decoder}) =>
    loadBytes(glb(root, binary: [42]), decoder: decoder);
Matcher failure(AssetLoadError code) =>
    isA<AssetLoadException>().having((e) => e.code, 'code', code);

void main() {
  test(
    'Draco position bounds may include quantization padding but must enclose vertices',
    () async {
      final padded = document();
      accessor(padded, 0)
        ..['min'] = [-1.001, -1.001, -.001]
        ..['max'] = [1.001, 1.001, .001];
      expect(await load(padded, decoder: Decoder()), isA<ModelAsset>());
      final invalid = document();
      accessor(invalid, 0)['min'] = [0, 0, 0];
      await expectLater(
        load(invalid, decoder: Decoder()),
        throwsA(failure(AssetLoadError.invalidData)),
      );
    },
  );
  test(
    'Draco triangle and strip topology becomes ordinary indexed geometry',
    () async {
      for (final mode in [4, 5]) {
        final model = await load(document(mode: mode), decoder: Decoder());
        final mesh =
            model.instantiate().children.single.children.single as Mesh;
        expect(mesh.geometry.positions, [
          -1,
          -1,
          0,
          1,
          -1,
          0,
          1,
          1,
          0,
          -1,
          -1,
          0,
          1,
          1,
          0,
          -1,
          1,
          0,
        ]);
        expect(mesh.geometry.indices, [0, 1, 2, 3, 4, 5]);
      }
    },
  );
  test(
    'required Draco needs a codec and optional Draco can use its fallback',
    () async {
      await expectLater(
        load(document()),
        throwsA(failure(AssetLoadError.unsupportedFeature)),
      );
      final bytes = triangleModel(
        changes: {
          'extensionsUsed': ['KHR_materials_unlit', extension],
          'meshes': [
            {
              'primitives': [
                {
                  'attributes': {'POSITION': 0},
                  'extensions': {
                    extension: {
                      'bufferView': 0,
                      'attributes': {'POSITION': 77},
                    },
                  },
                },
              ],
            },
          ],
        },
      );
      final model = await loadBytes(bytes);
      expect(
        model.issues.any((i) => i.code == 'gltf.unsupportedOptionalExtension'),
        isTrue,
      );
    },
  );
  test(
    'Draco accessors must match decoded count, type, range and attribute IDs',
    () async {
      for (final modify in <void Function(Map<String, Object?>)>[
        (r) => accessor(r, 0)['count'] = 3,
        (r) => accessor(r, 0)['type'] = 'VEC2',
        (r) => accessor(r, 0)['componentType'] = 5123,
        (r) => accessor(r, 1)['count'] = 3,
        (r) => accessor(r, 1)['normalized'] = true,
        (r) =>
            ((primitive(r)['extensions'] as Map)[extension]['attributes']
                    as Map)['POSITION'] =
                9,
        (r) =>
            ((primitive(r)['extensions'] as Map)[extension]['attributes']
                    as Map)['NORMAL'] =
                77,
      ]) {
        final root = document();
        modify(root);
        await expectLater(
          load(root, decoder: Decoder()),
          throwsA(failure(AssetLoadError.invalidData)),
        );
      }
    },
  );
  test('shared accessors get independent decoded primitive bindings', () async {
    final root = document(), decoder = Decoder();
    root['meshes'] = [
      {
        'primitives': [
          primitive(root),
          Map<String, Object?>.of(primitive(root)),
        ],
      },
    ];
    final model = await load(root, decoder: decoder);
    expect(model.instantiate().children.single.children, hasLength(2));
    expect(decoder.calls, 2);
  });
  test(
    'Draco ignores fallback buffer offsets and supports absent index accessors',
    () async {
      final root = document();
      accessor(root, 0)
        ..['bufferView'] = 999
        ..['byteOffset'] = 999;
      primitive(root).remove('indices');
      final model = await load(root, decoder: Decoder());
      final mesh = model.instantiate().children.single.children.single as Mesh;
      expect(mesh.geometry.indices, hasLength(6));
    },
  );
}
