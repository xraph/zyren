import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:test/test.dart';
import 'model_test.dart' show load;
import 'support/fixtures.dart';

Uint8List litModel(Map<String, Object?> light, {int instances = 1}) => glb({
  'asset': {'version': '2.0'},
  'extensionsUsed': ['KHR_lights_punctual'],
  'extensionsRequired': ['KHR_lights_punctual'],
  'extensions': {
    'KHR_lights_punctual': {
      'lights': [light],
    },
  },
  'nodes': [
    for (var i = 0; i < instances; i++)
      {
        'extensions': {
          'KHR_lights_punctual': {'light': 0},
        },
      },
  ],
  'scenes': [
    {
      'nodes': [for (var i = 0; i < instances; i++) i],
    },
  ],
});

void main() {
  test(
    'light definitions reject malformed values with exact field paths',
    () async {
      for (final (light, field, code)
          in <(Map<String, Object?>, String, AssetLoadError)>[
            ({}, 'type', AssetLoadError.invalidData),
            ({'type': 'area'}, 'type', AssetLoadError.invalidData),
            (
              {
                'type': 'point',
                'color': [1, 2, 1],
              },
              'color',
              AssetLoadError.invalidData,
            ),
            (
              {'type': 'point', 'color': null},
              'color',
              AssetLoadError.invalidData,
            ),
            (
              {'type': 'point', 'intensity': -1},
              'intensity',
              AssetLoadError.invalidData,
            ),
            (
              {'type': 'point', 'intensity': null},
              'intensity',
              AssetLoadError.invalidData,
            ),
            (
              {'type': 'point', 'intensity': 1e13},
              'intensity',
              AssetLoadError.unsupportedFeature,
            ),
            (
              {'type': 'point', 'range': 0},
              'range',
              AssetLoadError.invalidData,
            ),
            (
              {'type': 'point', 'range': null},
              'range',
              AssetLoadError.invalidData,
            ),
            (
              {'type': 'point', 'range': 1e-50},
              'range',
              AssetLoadError.unsupportedFeature,
            ),
            (
              {'type': 'directional', 'range': 1},
              'range',
              AssetLoadError.invalidData,
            ),
            ({'type': 'point', 'spot': {}}, 'spot', AssetLoadError.invalidData),
            ({'type': 'spot'}, 'spot', AssetLoadError.invalidData),
            (
              {
                'type': 'spot',
                'spot': {'innerConeAngle': -1},
              },
              'spot.innerConeAngle',
              AssetLoadError.invalidData,
            ),
            (
              {
                'type': 'spot',
                'spot': {'innerConeAngle': .5, 'outerConeAngle': .5},
              },
              'spot.outerConeAngle',
              AssetLoadError.invalidData,
            ),
            (
              {
                'type': 'spot',
                'spot': {'outerConeAngle': 2},
              },
              'spot.outerConeAngle',
              AssetLoadError.invalidData,
            ),
          ]) {
        await expectLater(
          load(litModel(light)),
          throwsA(
            isA<AssetLoadException>()
                .having((e) => e.code, 'code', code)
                .having(
                  (e) => e.fieldPath,
                  'field',
                  'extensions.KHR_lights_punctual.lights[0].$field',
                ),
          ),
        );
      }
    },
  );
  test(
    'light references require a declared extension and a valid definition',
    () async {
      for (final (edit, path) in <(void Function(Map<String, Object?>), String)>[
        (
          (root) => root.remove('extensions'),
          'nodes[0].extensions.KHR_lights_punctual.light',
        ),
        (
          (root) {
            root.remove('extensionsUsed');
            root.remove('extensionsRequired');
          },
          'extensions.KHR_lights_punctual',
        ),
        (
          (root) =>
              (root['nodes']
                      as List)[0]['extensions']['KHR_lights_punctual']['light'] =
                  1,
          'nodes[0].extensions.KHR_lights_punctual.light',
        ),
      ]) {
        await expectLater(
          load(editModel(litModel({'type': 'point'}), edit)),
          throwsA(
            isA<AssetLoadException>()
                .having((e) => e.code, 'code', AssetLoadError.invalidData)
                .having((e) => e.fieldPath, 'field', path),
          ),
        );
      }
    },
  );
  test(
    'light admission counts instances per scene and participates in cache keys',
    () async {
      final bytes = litModel({'type': 'point'}, instances: 2);
      await expectLater(
        load(
          bytes,
          options: const GltfOptions(limits: GltfLimits(maxLights: 1)),
        ),
        throwsA(
          isA<AssetLoadException>()
              .having((e) => e.code, 'code', AssetLoadError.limitExceeded)
              .having((e) => e.fieldPath, 'field', 'scenes[0]'),
        ),
      );
      final model = await load(
        editModel(bytes, (root) {
          root['scenes'] = [
            {
              'nodes': [0],
            },
            {
              'nodes': [1],
            },
          ];
        }),
        options: const GltfOptions(limits: GltfLimits(maxLights: 1)),
      );
      expect(
        model.instantiate(sceneIndex: 0).children.single.children.single,
        isA<PointLight>(),
      );
      expect(
        model.instantiate(sceneIndex: 1).children.single.children.single,
        isA<PointLight>(),
      );
      expect(const GltfLimits(), isNot(const GltfLimits(maxLights: 1)));
      expect(
        () => Gltf.asset(
          'model.glb',
          options: const GltfOptions(limits: GltfLimits(maxLights: 17)),
        ),
        throwsRangeError,
      );
    },
  );
  test('light defaults and nested transforms survive instantiation', () async {
    final model = await load(
      editModel(litModel({'type': 'spot', 'spot': {}}), (root) {
        root['nodes'] = [
          {
            'translation': [10, 0, 0],
            'scale': [2, 3, 4],
            'children': [1],
          },
          {
            'translation': [1, 2, 3],
            'extensions': {
              'KHR_lights_punctual': {'light': 0},
            },
          },
        ];
      }),
    );
    final instance = model.instantiate();
    final spot =
        instance.children.single.children.single.children.single as SpotLight;
    expect(spot.intensity, 1);
    expect(spot.range, isNull);
    expect(spot.color, const Color3(1, 1, 1));
    expect(spot.innerConeAngle, 0);
    expect(spot.outerConeAngle, closeTo(.7853981633974483, 1e-12));
    final world =
        instance.children.single.localMatrix *
        spot.parent!.localMatrix *
        spot.localMatrix;
    expect(world.storage.sublist(12, 15), [12, 6, 12]);
  });
}
