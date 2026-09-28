import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:test/test.dart';
import 'geometry_model_test.dart' show onlyMesh;
import 'model_test.dart' show load;
import 'support/fixtures.dart';

void main() {
  test('unlit factors, sides and mask cutoffs retain glTF values', () async {
    final model = await load(
      primitiveModel(
        indices: [0, 1, 2],
        changes: {
          'materials': [
            {
              'extensions': {'KHR_materials_unlit': <String, Object?>{}},
              'doubleSided': true,
              'alphaMode': 'MASK',
              'alphaCutoff': 1.1,
              'pbrMetallicRoughness': {
                'baseColorFactor': [.2, .4, .6, .8],
              },
            },
          ],
        },
      ),
    );
    final material = onlyMesh(model).material;
    expect(material.color, const Color3(.2, .4, .6));
    expect(material.opacity, .8);
    expect(material.alphaMode, MaterialAlphaMode.mask);
    expect(material.alphaCutoff, 1.1);
    expect(material.side, MaterialSide.doubleSided);
  });
  test('unsupported deformation and color features fail explicitly', () async {
    for (final bytes in [
      triangleModel(
        changes: {
          'animations': [{}],
        },
      ),
      triangleModel(
        changes: {
          'nodes': [
            {'mesh': 0, 'skin': 0},
          ],
        },
      ),
      triangleModel(
        changes: {
          'nodes': [
            {'mesh': 0, 'camera': 0},
          ],
        },
      ),
      primitiveModel(
        indices: [0, 1, 2],
        primitiveChanges: {
          'targets': [{}],
        },
      ),
      primitiveModel(
        indices: [0, 1, 2],
        primitiveChanges: {
          'attributes': {'POSITION': 0, 'COLOR_1': 0},
        },
      ),
    ]) {
      await expectLater(
        load(bytes),
        throwsA(
          isA<AssetLoadException>()
              .having((e) => e.code, 'code', AssetLoadError.unsupportedFeature)
              .having((e) => e.fieldPath, 'path', isNotNull),
        ),
      );
    }
  });
  test(
    'explicit nulls and invalid material fields retain diagnostics',
    () async {
      for (final changes in <Map<String, Object?>>[
        {'doubleSided': null},
        {'alphaMode': 'OTHER'},
        {'alphaCutoff': -1},
        {
          'pbrMetallicRoughness': {
            'baseColorFactor': [1, 2, 1, 1],
          },
        },
        {
          'pbrMetallicRoughness': {'baseColorTexture': null},
        },
      ]) {
        final bytes = primitiveModel(
          indices: [0, 1, 2],
          changes: {
            'materials': [
              {
                'extensions': {'KHR_materials_unlit': <String, Object?>{}},
                ...changes,
              },
            ],
          },
        );
        await expectLater(
          load(bytes),
          throwsA(
            isA<AssetLoadException>()
                .having((e) => e.code, 'code', AssetLoadError.invalidData)
                .having((e) => e.fieldPath, 'path', startsWith('materials[0]')),
          ),
        );
      }
    },
  );
  test('a missing material uses glTF PBR defaults', () async {
    final bytes = editModel(primitiveModel(indices: [0, 1, 2]), (root) {
      ((root['meshes'] as List).first['primitives'] as List).first.remove(
        'material',
      );
    });
    final standard = await load(bytes);
    final material = onlyMesh(standard).material as StandardMaterial;
    expect(material.baseColor, const Color3(1, 1, 1));
    expect(material.metallic, 1);
    expect(material.roughness, 1);
    expect(standard.issues, isEmpty);
    final model = await load(
      bytes,
      options: const GltfOptions(
        materialMode: GltfMaterialMode.unlitDiagnostic,
      ),
    );
    expect(onlyMesh(model).material.color, const Color3(1, 1, 1));
    expect(model.issues.single.code, 'gltf.unlitDiagnostic');
  });
}
