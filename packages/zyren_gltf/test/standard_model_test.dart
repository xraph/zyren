import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:test/test.dart';
import 'geometry_model_test.dart' show onlyMesh;
import 'model_test.dart' show load;
import 'image_model_test.dart' show Images, ImageSources, scopeFor;
import 'support/fixtures.dart';
import 'tangent_model_test.dart' show TestTangents;

void main() {
  test(
    'invalid standard factors and map references fail before image decoding',
    () async {
      final cases = <(Map<String, Object?>, String)>[
        (
          {
            'pbrMetallicRoughness': {'metallicFactor': 1.1},
          },
          'metallicFactor',
        ),
        (
          {
            'pbrMetallicRoughness': {'roughnessFactor': -1},
          },
          'roughnessFactor',
        ),
        (
          {
            'emissiveFactor': [1, -1, 0],
          },
          'emissiveFactor',
        ),
        (
          {
            'normalTexture': {'index': 0, 'scale': null},
          },
          'normalTexture.scale',
        ),
        (
          {
            'occlusionTexture': {'index': 0, 'strength': 2},
          },
          'occlusionTexture.strength',
        ),
        (
          {
            'emissiveTexture': {'index': 9},
          },
          'emissiveTexture.index',
        ),
        (
          {
            'pbrMetallicRoughness': {
              'metallicRoughnessTexture': {'index': -1},
            },
          },
          'metallicRoughnessTexture.index',
        ),
      ];
      for (final (material, path) in cases) {
        final images = Images();
        final scope = scopeFor(
          ImageSources(texturedModel(materials: [material])),
          images,
        );
        await expectLater(
          scope.load(Gltf.asset('invalid.glb')).result,
          throwsA(
            isA<AssetLoadException>()
                .having((e) => e.code, 'code', AssetLoadError.invalidData)
                .having((e) => e.fieldPath, 'path', endsWith(path)),
          ),
        );
        expect(images.calls, 0);
      }
      for (final key in [
        'normalTexture',
        'occlusionTexture',
        'emissiveTexture',
        'metallicRoughnessTexture',
      ]) {
        final map = {'index': 0, 'texCoord': 1};
        final material = key == 'metallicRoughnessTexture'
            ? {
                'pbrMetallicRoughness': {key: map},
              }
            : {key: map};
        await expectLater(
          load(texturedModel(materials: [material])),
          throwsA(
            isA<AssetLoadException>().having(
              (e) => e.fieldPath,
              'path',
              'meshes[0].primitives[0].attributes.TEXCOORD_1',
            ),
          ),
        );
      }
    },
  );
  test(
    'punctual light schema and active scene limits fail with field diagnostics',
    () async {
      Map<String, Object?> definition(Map<String, Object?> light) => {
        'extensionsUsed': ['KHR_lights_punctual'],
        'extensions': {
          'KHR_lights_punctual': {
            'lights': [light],
          },
        },
        'nodes': [
          {
            'extensions': {
              'KHR_lights_punctual': {'light': 0},
            },
          },
        ],
      };
      for (final light in <Map<String, Object?>>[
        {'type': 'unknown'},
        {'type': 'point', 'intensity': -1},
        {
          'type': 'point',
          'color': [1, 1, 2],
        },
        {'type': 'point', 'range': 0},
        {'type': 'directional', 'range': 1},
        {'type': 'spot'},
        {
          'type': 'spot',
          'spot': {'innerConeAngle': .5, 'outerConeAngle': .5},
        },
        {
          'type': 'spot',
          'spot': {'outerConeAngle': 1.6},
        },
        {'type': 'point', 'spot': <String, Object?>{}},
      ]) {
        await expectLater(
          load(triangleModel(unlit: false, changes: definition(light))),
          throwsA(
            isA<AssetLoadException>()
                .having((e) => e.code, 'code', AssetLoadError.invalidData)
                .having(
                  (e) => e.fieldPath,
                  'path',
                  startsWith('extensions.KHR_lights_punctual.lights[0]'),
                ),
          ),
        );
      }
      final invalidRef = definition({'type': 'point'})
        ..['nodes'] = [
          {
            'extensions': {
              'KHR_lights_punctual': {'light': 1},
            },
          },
        ];
      await expectLater(
        load(triangleModel(unlit: false, changes: invalidRef)),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.fieldPath,
            'path',
            'nodes[0].extensions.KHR_lights_punctual.light',
          ),
        ),
      );
      final missingDeclaration = definition({'type': 'point'})
        ..remove('extensionsUsed');
      await expectLater(
        load(triangleModel(unlit: false, changes: missingDeclaration)),
        throwsA(isA<AssetLoadException>()),
      );
      final crowded = definition({'type': 'point'})
        ..['nodes'] = [
          for (var i = 0; i < 17; i++)
            {
              'extensions': {
                'KHR_lights_punctual': {'light': 0},
              },
            },
        ]
        ..['scenes'] = [
          {
            'nodes': [for (var i = 0; i < 17; i++) i],
          },
        ];
      await expectLater(
        load(triangleModel(unlit: false, changes: crowded)),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
      crowded['scenes'] = [
        {
          'nodes': [0],
        },
      ];
      expect(
        (await load(
          triangleModel(unlit: false, changes: crowded),
        )).instantiate().children,
        hasLength(1),
      );
    },
  );
  test(
    'standard materials share image decode while preserving color and data formats',
    () async {
      final bytes = editModel(
        texturedModel(
          materials: [
            {
              'pbrMetallicRoughness': {
                'baseColorFactor': [.5, .4, .3, .7],
                'metallicFactor': .3,
                'roughnessFactor': .6,
                'baseColorTexture': {'index': 0},
                'metallicRoughnessTexture': {'index': 0},
              },
              'normalTexture': {'index': 0, 'scale': -.5},
              'occlusionTexture': {'index': 0, 'texCoord': 1, 'strength': .4},
              'emissiveTexture': {'index': 0},
              'emissiveFactor': [.1, .2, .3],
              'alphaMode': 'BLEND',
              'doubleSided': true,
            },
          ],
        ),
        (root) {
          final attributes =
              (root['meshes'] as List)[0]['primitives'][0]['attributes'] as Map;
          attributes['TEXCOORD_1'] = attributes['TEXCOORD_0'];
        },
      );
      final images = Images();
      // A single decoder feeds both texture variants.
      final source = ImageSources(bytes),
          shared = scopeFor(source, images, tangentGenerator: TestTangents());
      final model = await shared.load(Gltf.asset('standard.glb')).result;
      final material = onlyMesh(model).material as StandardMaterial;
      expect(images.calls, 1);
      expect(material.metallic, .3);
      expect(material.roughness, .6);
      expect(material.emissive, const Color3(.1, .2, .3));
      expect(material.opacity, .7);
      expect(material.side, MaterialSide.doubleSided);
      expect(material.alphaMode, MaterialAlphaMode.blend);
      expect(material.normalScaleX, -.5);
      expect(material.normalScaleY, -.5);
      expect(material.occlusionStrength, .4);
      expect(material.occlusionMap!.uvSet, 1);
      expect(
        material.colorMap!.image.descriptor.format,
        TextureFormat.rgba8UnormSrgb,
      );
      expect(
        material.normalMap!.image.descriptor.format,
        TextureFormat.rgba8Unorm,
      );
      expect(material.emissiveMap!.image, same(material.colorMap!.image));
      expect(
        material.normalMap!.image,
        same(material.metallicRoughnessMap!.image),
      );
      expect(material.normalMap!.image, same(material.occlusionMap!.image));
      expect(
        material.normalMap!.image.levels[0],
        material.colorMap!.image.levels[0],
      );
    },
  );
  test(
    'authored tangents survive triangle loading and flat normals ignore supplied tangents',
    () async {
      final values = [
        for (var i = 0; i < 4; i++) ...[1.0, 0.0, 0.0, -1.0],
      ];
      final supplied = await load(
        primitiveModel(
          indices: [0, 1, 2, 0, 2, 3],
          normals: [
            for (var i = 0; i < 4; i++) ...[0.0, 0.0, 1.0],
          ],
          tangents: values,
        ),
      );
      expect(
        onlyMesh(supplied).geometry.attributes[VertexSemantic.tangent]!.data,
        values,
      );
      final flat = await load(
        primitiveModel(indices: [0, 1, 2, 0, 2, 3], tangents: values),
      );
      expect(
        onlyMesh(flat).geometry.attributes.containsKey(VertexSemantic.tangent),
        isFalse,
      );
    },
  );
  test(
    'punctual light instances preserve photometric values and clone independently',
    () async {
      final model = await load(
        triangleModel(
          unlit: false,
          changes: {
            'extensionsUsed': ['KHR_lights_punctual'],
            'extensionsRequired': ['KHR_lights_punctual'],
            'extensions': {
              'KHR_lights_punctual': {
                'lights': [
                  {
                    'type': 'directional',
                    'color': [.2, .4, .6],
                    'intensity': 3,
                  },
                  {'type': 'point', 'intensity': 8, 'range': 20},
                  {
                    'type': 'spot',
                    'spot': {
                      'innerConeAngle': .2,
                      'outerConeAngle': math.pi / 2,
                    },
                  },
                ],
              },
            },
            'nodes': [
              {
                'children': [1, 2, 3],
                'scale': [2, 2, 2],
              },
              for (var i = 0; i < 3; i++)
                {
                  'extensions': {
                    'KHR_lights_punctual': {'light': i},
                  },
                },
            ],
          },
        ),
      );
      final first = model.instantiate(), second = model.instantiate();
      final nodes = first.children.single.children;
      final sun = nodes[0].children.single as DirectionalLight;
      final point = nodes[1].children.single as PointLight;
      final spot = nodes[2].children.single as SpotLight;
      expect(sun.intensity, 3);
      expect(sun.color, const Color3(.2, .4, .6));
      expect(sun.direction, const Vec3(0, 0, -1));
      expect(point.intensity, 8);
      expect(point.range, 20);
      expect(spot.angle, math.pi / 2);
      expect(spot.penumbra, closeTo(1 - .2 / (math.pi / 2), 1e-12));
      sun.intensity = 1;
      expect(
        (second.children.single.children[0].children.single as DirectionalLight)
            .intensity,
        3,
      );
    },
  );
}
