import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:test/test.dart';
import 'geometry_model_test.dart' show onlyMesh;
import 'model_test.dart' show load;
import 'image_model_test.dart' show ImageSources, Images, scopeFor;
import 'support/fixtures.dart';
import 'support/pbr_fixture.dart';
import 'tangent_model_test.dart' show TestTangents;

Uint8List physicalModel(
  Map<String, Object?> extensions, {
  bool tangents = true,
}) => editModel(
  pbrModel(
    material: {
      'emissiveFactor': [.2, .3, .4],
      'extensions': extensions,
    },
  ),
  (root) {
    root['scenes'] = [
      {
        'nodes': [0],
      },
    ];
    root['extensionsUsed'] = ['KHR_lights_punctual', ...extensions.keys];
    root['extensionsRequired'] = ['KHR_lights_punctual', ...extensions.keys];
    if (!tangents) {
      ((root['meshes'] as List).first['primitives'][0]['attributes'] as Map)
          .remove('TANGENT');
    }
  },
);
void main() {
  test(
    'required physical glTF extensions publish factors and all map channels',
    () async {
      final bytes = physicalModel({
        'KHR_materials_ior': {'ior': 2.1},
        'KHR_materials_specular': {
          'specularFactor': .6,
          'specularColorFactor': [2, 1, .5],
          'specularTexture': {'index': 0},
          'specularColorTexture': {'index': 0},
        },
        'KHR_materials_clearcoat': {
          'clearcoatFactor': .8,
          'clearcoatRoughnessFactor': .3,
          'clearcoatTexture': {'index': 0},
          'clearcoatRoughnessTexture': {'index': 0},
          'clearcoatNormalTexture': {'index': 2, 'scale': -.7},
        },
        'KHR_materials_sheen': {
          'sheenColorFactor': [.2, .3, .4],
          'sheenRoughnessFactor': .5,
          'sheenColorTexture': {'index': 0},
          'sheenRoughnessTexture': {'index': 0},
        },
        'KHR_materials_anisotropy': {
          'anisotropyStrength': .9,
          'anisotropyRotation': 1.2,
          'anisotropyTexture': {'index': 0},
        },
        'KHR_materials_emissive_strength': {'emissiveStrength': 7},
        'KHR_materials_transmission': {
          'transmissionFactor': .8,
          'transmissionTexture': {'index': 0},
        },
        'KHR_materials_volume': {
          'thicknessFactor': 2,
          'thicknessTexture': {'index': 0},
          'attenuationDistance': 4,
          'attenuationColor': [.3, .5, .7],
        },
      });
      final scope = scopeFor(ImageSources(bytes), Images());
      final model = await scope.load(Gltf.asset('physical.glb')).result;
      final p = onlyMesh(model).material as PhysicalMaterial;
      expect(p.ior, 2.1);
      expect(p.specularIntensity, .6);
      expect(p.specularColor, const Color3(2, 1, .5));
      expect(p.clearcoat, .8);
      expect(p.clearcoatRoughness, .3);
      expect(p.clearcoatNormalScale, -.7);
      expect(p.sheenColor, const Color3(.2, .3, .4));
      expect(p.sheenRoughness, .5);
      expect(p.anisotropy, .9);
      expect(p.anisotropyRotation, 1.2);
      expect(p.emissiveIntensity, 7);
      expect(p.textureMaps.length, 10);
      expect(p.transmission, .8);
      expect(p.thickness, 2);
      expect(p.attenuationDistance, 4);
      expect(p.attenuationColor, const Color3(.3, .5, .7));
      expect(p.transmissionMap!.image, same(p.clearcoatMap!.image));
      expect(p.thicknessMap!.image, same(p.transmissionMap!.image));
      expect(p.clearcoatMap!.image, same(p.sheenRoughnessMap!.image));
      expect(p.specularColorMap!.image, same(p.sheenColorMap!.image));
      expect(p.specularColorMap!.image, isNot(same(p.clearcoatMap!.image)));
      expect(p.clearcoatMap!.image.descriptor.format, TextureFormat.rgba8Unorm);
      expect(
        p.specularColorMap!.image.descriptor.format,
        TextureFormat.rgba8UnormSrgb,
      );
      expect(model.issues, isEmpty);
    },
  );
  test(
    'physical defaults, ideal reflectors and emissive intensity stay distinct',
    () async {
      final sheen =
          onlyMesh(
                await load(physicalModel({'KHR_materials_sheen': {}})),
              ).material
              as PhysicalMaterial;
      expect(sheen.sheenRoughness, 0);
      expect(sheen.ior, 1.5);
      expect(sheen.clearcoat, 0);
      final ideal =
          onlyMesh(
                await load(
                  physicalModel({
                    'KHR_materials_ior': {'ior': 0},
                  }),
                ),
              ).material
              as PhysicalMaterial;
      expect(ideal.ior, 0);
      final emission = onlyMesh(
        await load(
          physicalModel({
            'KHR_materials_emissive_strength': {'emissiveStrength': 3},
          }),
        ),
      ).material;
      expect(emission, isNot(isA<PhysicalMaterial>()));
      expect((emission as StandardMaterial).emissiveIntensity, 3);
    },
  );
  test(
    'missing physical tangent frames use the declared texture UV set',
    () async {
      for (final name in ['clearcoat', 'anisotropy']) {
        final key = name == 'clearcoat'
            ? 'clearcoatNormalTexture'
            : 'anisotropyTexture';
        final source = editModel(
          physicalModel({
            'KHR_materials_$name': {
              key: {'index': 2, 'texCoord': 1},
              if (name == 'anisotropy') 'anisotropyStrength': .7,
            },
          }, tangents: false),
          (root) {
            final a =
                (root['meshes'] as List).first['primitives'][0]['attributes']
                    as Map;
            a['TEXCOORD_1'] = a['TEXCOORD_0'];
          },
        );
        final generator = TestTangents();
        final scope = scopeFor(
          ImageSources(source),
          Images(),
          tangentGenerator: generator,
        );
        final model = await scope.load(Gltf.asset('$name.glb')).result;
        expect(generator.calls, 1);
        expect(generator.selectedUv, 1);
        expect(onlyMesh(model).geometry.capture().tangents, isNotNull);
      }
    },
  );
  test(
    'physical malformed factors, incompatible extensions and missing UVs fail before publication',
    () async {
      for (final extensions in <Map<String, Object?>>[
        {
          'KHR_materials_ior': {'ior': .5},
        },
        {
          'KHR_materials_specular': {'specularFactor': 2},
        },
        {
          'KHR_materials_sheen': {
            'sheenColorFactor': [1, -1, 0],
          },
        },
        {
          'KHR_materials_clearcoat': {'clearcoatRoughnessFactor': null},
        },
        {
          'KHR_materials_emissive_strength': {'emissiveStrength': -1},
        },
        {'KHR_materials_unlit': {}, 'KHR_materials_clearcoat': {}},
        {
          'KHR_materials_volume': {'attenuationDistance': 0},
        },
        {
          'KHR_materials_volume': {'thicknessFactor': -1},
        },
        {
          'KHR_materials_transmission': {'transmissionFactor': 2},
        },
        {
          'KHR_materials_clearcoat': {
            'clearcoatTexture': {'index': 0, 'texCoord': 1},
          },
        },
      ]) {
        final scope = scopeFor(
          ImageSources(physicalModel(extensions)),
          Images(),
        );
        await expectLater(
          scope.load(Gltf.asset('bad.glb')).result,
          throwsA(isA<AssetLoadException>()),
        );
      }
    },
  );
}
