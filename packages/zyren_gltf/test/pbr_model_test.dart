import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:test/test.dart';
import 'geometry_model_test.dart' show onlyMesh;
import 'model_test.dart' show load, triangleIn;
import 'image_model_test.dart' show Images, ImageSources, scopeFor;
import 'support/fixtures.dart';
import 'tangent_model_test.dart' show TestTangents;

void main() {
  test(
    'standard glTF defaults and authored factors publish core materials',
    () async {
      final defaults = await load(triangleModel(unlit: false));
      final material =
          triangleIn(defaults.instantiate()).material as StandardMaterial;
      expect(material.metallic, 1);
      expect(material.roughness, 1);
      final model = await load(
        primitiveModel(
          indices: [0, 1, 2],
          changes: {
            'materials': [
              {
                'pbrMetallicRoughness': {
                  'baseColorFactor': [.2, .4, .6, .8],
                  'metallicFactor': .3,
                  'roughnessFactor': .7,
                },
                'emissiveFactor': [.1, .2, .3],
                'alphaMode': 'MASK',
                'alphaCutoff': .4,
                'doubleSided': true,
              },
            ],
          },
        ),
      );
      final pbr = onlyMesh(model).material as StandardMaterial;
      expect(pbr.baseColor, const Color3(.2, .4, .6));
      expect(pbr.opacity, .8);
      expect(pbr.metallic, .3);
      expect(pbr.roughness, .7);
      expect(pbr.emissive, const Color3(.1, .2, .3));
      expect(pbr.alphaMode, MaterialAlphaMode.mask);
      expect(pbr.alphaCutoff, .4);
      expect(pbr.side, MaterialSide.doubleSided);
      expect(model.issues, isEmpty);
    },
  );
  test(
    'one source image has separate linear and sRGB variants shared by map usage',
    () async {
      final bytes = editModel(texturedModel(), (root) {
        root['materials'] = [
          {
            'pbrMetallicRoughness': {
              'baseColorTexture': {'index': 0},
              'metallicRoughnessTexture': {'index': 0},
            },
            'normalTexture': {'index': 0, 'scale': -.5},
            'occlusionTexture': {'index': 0, 'strength': .25},
            'emissiveTexture': {'index': 0},
            'emissiveFactor': [1, 1, 1],
          },
        ];
      });
      final images = Images();
      final scope = scopeFor(
        ImageSources(bytes),
        images,
        tangentGenerator: TestTangents(),
      );
      final model = await scope.load(Gltf.asset('model.glb')).result;
      final material = onlyMesh(model).material as StandardMaterial;
      expect(images.calls, 1);
      expect(
        material.baseColorMap!.image.descriptor.format,
        TextureFormat.rgba8UnormSrgb,
      );
      expect(
        material.normalMap!.image.descriptor.format,
        TextureFormat.rgba8Unorm,
      );
      expect(material.emissiveMap!.image, same(material.baseColorMap!.image));
      expect(material.occlusionMap!.image, same(material.normalMap!.image));
      expect(
        material.metallicRoughnessMap!.image,
        same(material.normalMap!.image),
      );
      expect(material.normalScale, -.5);
      expect(material.occlusionStrength, .25);
      expect(
        material.normalMap!.image.levels.single,
        material.baseColorMap!.image.levels.single,
      );
    },
  );
  test(
    'punctual light instances preserve authored units and isolate edits',
    () async {
      final bytes = triangleModel(
        unlit: false,
        changes: {
          'extensionsUsed': ['KHR_lights_punctual'],
          'extensionsRequired': ['KHR_lights_punctual'],
          'extensions': {
            'KHR_lights_punctual': {
              'lights': [
                {
                  'type': 'point',
                  'color': [.2, .4, .8],
                  'intensity': 20,
                  'range': 12,
                  'name': 'Bulb',
                },
                {'type': 'directional'},
                {
                  'type': 'spot',
                  'spot': {'innerConeAngle': .2, 'outerConeAngle': .6},
                },
              ],
            },
          },
          'nodes': [
            {
              'mesh': 0,
              'scale': [2, 3, 4],
              'translation': [1, 2, 3],
              'extensions': {
                'KHR_lights_punctual': {'light': 0},
              },
            },
            {
              'extensions': {
                'KHR_lights_punctual': {'light': 1},
              },
            },
            {
              'extensions': {
                'KHR_lights_punctual': {'light': 2},
              },
            },
          ],
          'scenes': [
            {
              'nodes': [0, 1, 2],
            },
          ],
        },
      );
      final model = await load(bytes);
      final first = model.instantiate(), second = model.instantiate();
      final point = first.children[0].children.whereType<PointLight>().single;
      expect(point.name, 'Bulb');
      expect(point.intensity, 20);
      expect(point.range, 12);
      expect(point.color, const Color3(.2, .4, .8));
      expect(first.children[1].children.single, isA<DirectionalLight>());
      final spot = first.children[2].children.single as SpotLight;
      expect(spot.innerConeAngle, .2);
      expect(spot.outerConeAngle, .6);
      point.intensity = 5;
      expect(
        second.children[0].children.whereType<PointLight>().single.intensity,
        20,
      );
    },
  );
  test(
    'unlit ignores lighting-only maps without decoding their images',
    () async {
      final bytes = editModel(texturedModel(), (root) {
        final material = (root['materials'] as List).single as Map;
        material['normalTexture'] = {'index': 999};
        material['occlusionTexture'] = {'index': 999};
        material['emissiveTexture'] = {'index': 999};
        material['emissiveFactor'] = [1, 1, 1];
        (material['pbrMetallicRoughness'] as Map)['metallicRoughnessTexture'] =
            {'index': 999};
      });
      final images = Images();
      final scope = scopeFor(ImageSources(bytes), images);
      final model = await scope.load(Gltf.asset('unlit.glb')).result;
      expect(onlyMesh(model).material, isA<UnlitMaterial>());
      expect(images.calls, 1);
      expect(model.issues, isEmpty);
    },
  );
  test(
    'PBR maps require their UV set and preserve field diagnostics',
    () async {
      for (final (fields, path, code)
          in <(Map<String, Object?>, String, AssetLoadError)>[
            (
              {'normalTexture': null},
              'normalTexture',
              AssetLoadError.invalidData,
            ),
            (
              {
                'normalTexture': {'index': 0, 'scale': null},
              },
              'normalTexture.scale',
              AssetLoadError.invalidData,
            ),
            (
              {
                'normalTexture': {'index': 0, 'scale': 1e7},
              },
              'normalTexture.scale',
              AssetLoadError.unsupportedFeature,
            ),
            (
              {
                'occlusionTexture': {'index': 0, 'strength': 1.1},
              },
              'occlusionTexture.strength',
              AssetLoadError.invalidData,
            ),
            (
              {
                'emissiveFactor': [1, -.1, 0],
              },
              'emissiveFactor',
              AssetLoadError.invalidData,
            ),
            (
              {
                'emissiveTexture': {'index': 0, 'texCoord': 2},
              },
              'emissiveTexture.texCoord',
              AssetLoadError.unsupportedFeature,
            ),
          ]) {
        final bytes = editModel(texturedModel(), (root) {
          root['materials'] = [fields];
        });
        final scope = scopeFor(ImageSources(bytes), Images());
        await expectLater(
          scope.load(Gltf.asset('model.glb')).result,
          throwsA(
            isA<AssetLoadException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.fieldPath, 'field', 'materials[0].$path'),
          ),
        );
      }
      for (final map in [
        'normalTexture',
        'occlusionTexture',
        'emissiveTexture',
        'metallicRoughnessTexture',
      ]) {
        final bytes = editModel(texturedModel(), (root) {
          root['materials'] = [
            map == 'metallicRoughnessTexture'
                ? {
                    'pbrMetallicRoughness': {
                      map: {'index': 0, 'texCoord': 1},
                    },
                  }
                : {
                    map: {'index': 0, 'texCoord': 1},
                  },
          ];
          ((root['meshes'] as List).single['primitives'] as List)
              .single['attributes']
              .remove('TEXCOORD_1');
        });
        final scope = scopeFor(ImageSources(bytes), Images());
        await expectLater(
          scope.load(Gltf.asset('model.glb')).result,
          throwsA(
            isA<AssetLoadException>().having(
              (e) => e.fieldPath,
              'field',
              'meshes[0].primitives[0].attributes.TEXCOORD_1',
            ),
          ),
        );
      }
    },
  );
  test(
    'authored tangents retain handedness when normals are supplied',
    () async {
      final tangents = [
        for (var i = 0; i < 4; i++) ...[1.0, 0.0, 0.0, -1.0],
      ];
      final model = await load(
        primitiveModel(
          indices: [0, 1, 2, 0, 2, 3],
          normals: [
            for (var i = 0; i < 4; i++) ...[0.0, 0.0, 1.0],
          ],
          tangents: tangents,
        ),
      );
      expect(
        onlyMesh(model).geometry.attributes[VertexSemantic.tangent]?.data,
        tangents,
      );
      final flat = await load(
        primitiveModel(indices: [0, 1, 2, 0, 2, 3], tangents: tangents),
      );
      expect(
        onlyMesh(flat).geometry.attributes[VertexSemantic.tangent]?.data,
        isNull,
      );
    },
  );
  test('each color-space variant participates in decoded admission', () async {
    final bytes = editModel(texturedModel(imageUri: 'corners.png'), (root) {
      root['materials'] = [
        {
          'pbrMetallicRoughness': {
            'baseColorTexture': {'index': 0},
          },
          'occlusionTexture': {'index': 0},
        },
      ];
    });
    // 280 geometry + 16 decoded RGBA + two 16-byte owned texture variants.
    for (final budget in [327, 328]) {
      final scope = scopeFor(
        ImageSources(bytes),
        Images(),
        limits: AssetLimits(maxDecodedBytes: budget),
      );
      final result = scope.load(Gltf.asset('model.glb')).result;
      if (budget == 327) {
        await expectLater(
          result,
          throwsA(
            isA<AssetLoadException>().having(
              (e) => e.code,
              'code',
              AssetLoadError.limitExceeded,
            ),
          ),
        );
      } else {
        expect(onlyMesh(await result).material, isA<StandardMaterial>());
      }
    }
  });
}
