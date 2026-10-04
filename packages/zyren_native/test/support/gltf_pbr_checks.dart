import 'dart:math' as math;
import 'brdf_reference.dart';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';
import '../../../zyren_gltf/test/support/pbr_fixture.dart';
import '../../../zyren_gltf/test/support/fixtures.dart' show editModel;

final class _Source implements ByteSourceResolver {
  final Uint8List bytes;
  _Source(this.bytes);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(effectiveUri: uri, bytes: bytes);
}

Future<void> verifyGltfPbr(NativeGpuBackend backend) async {
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 2));
  Future<List<int>> render(
    Uint8List bytes, {
    void Function(Scene)? configure,
    bool generatedTangents = false,
  }) async {
    final assets = AssetScope(
      services: AssetServices(
        resolver: _Source(bytes),
        imageDecoder: const NativeImageDecoder(),
        tangentGenerator: const NativeTangentGenerator(),
      ),
    );
    try {
      final model = await assets.load(Gltf.asset('pbr.glb')).result;
      expect(model.issues, isEmpty);
      final scene = Scene()
        ..background = const Color3(0, 0, 0)
        ..add(model.instantiate());
      if (generatedTangents) {
        void check(Object3D object) {
          if (object is Mesh) {
            expect(
              object.geometry.attributes[VertexSemantic.tangent],
              isNotNull,
            );
          }
          for (final child in object.children) {
            check(child);
          }
        }

        check(scene);
      }
      configure?.call(scene);
      final frame =
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: PhysicalSize(31, 31),
                ),
              )
              as ReadbackOutput;
      return frame.image.pixels.sublist(1920, 1924);
    } finally {
      await assets.close();
    }
  }

  void pixel(List<int> actual, List<int> expected) {
    for (var i = 0; i < 4; i++) {
      expect(
        actual[i],
        closeTo(expected[i], 2),
        reason: 'glTF pixel $actual vs $expected',
      );
    }
  }

  int encode(double value) =>
      ((value <= .0031308
                  ? value * 12.92
                  : 1.055 * math.pow(value, 1 / 2.4) - .055) *
              255)
          .round();
  double radiance(double base, double metallic) => referenceRadiance(
    view: const Vec3(0, 0, 1),
    light: const Vec3(0, 0, 1),
    base: Color3(base, base, base),
    metallic: metallic,
    roughness: 1,
  ).first;
  List<int> grey(double metallic, [double intensity = 1]) => [
    for (var c = 0; c < 3; c++) encode(radiance(.5, metallic) * intensity),
    255,
  ];
  // The independent VNDF integral supplies the multiple-scattering energy.
  // Light and view are normal to the fixture; retain linear mixing before sRGB.
  pixel(await render(pbrModel()), grey(0));
  pixel(
    await render(
      pbrModel(
        material: {
          'pbrMetallicRoughness': {
            'baseColorFactor': [.5, .5, .5, 1],
            'metallicFactor': .5,
          },
        },
      ),
    ),
    grey(.5),
  );
  pixel(
    await render(
      pbrModel(
        material: {
          'pbrMetallicRoughness': {
            'baseColorFactor': [.5, .5, .5, 1],
          },
        },
      ),
    ),
    grey(1),
  );
  pixel(
    await render(pbrModel(light: {'type': 'directional', 'intensity': 0})),
    [0, 0, 0, 255],
  );
  pixel(
    await render(
      pbrModel(
        light: {'type': 'point', 'intensity': 4},
        lightNode: {
          'translation': [0, 0, 2],
          'scale': [2, 3, 4],
        },
      ),
    ),
    grey(0),
  );
  pixel(
    await render(
      pbrModel(
        light: {'type': 'point', 'intensity': 4},
        lightNode: {
          'translation': [0, 0, 4],
        },
      ),
    ),
    grey(0, .25),
  );
  pixel(
    await render(
      pbrModel(
        light: {'type': 'point', 'intensity': 4, 'range': 1},
        lightNode: {
          'translation': [0, 0, 2],
          'scale': [4, 4, 4],
        },
      ),
    ),
    [0, 0, 0, 255],
  );
  pixel(
    await render(
      pbrModel(
        light: {'type': 'spot', 'intensity': 4, 'spot': {}},
        lightNode: {
          'translation': [0, 0, 2],
          'scale': [2, 3, 4],
        },
      ),
    ),
    grey(0),
  );
  pixel(
    await render(
      pbrModel(
        light: {'type': 'spot', 'intensity': 4, 'spot': {}},
        lightNode: {
          'translation': [0, 0, 2],
          'rotation': [0, 1, 0, 0],
        },
      ),
    ),
    [0, 0, 0, 255],
  );
  pixel(
    await render(
      pbrModel(
        lightNode: {
          'rotation': [0, 1, 0, 0],
        },
      ),
    ),
    [0, 0, 0, 255],
  );

  final mapped = <String, Object?>{
    'pbrMetallicRoughness': {
      'baseColorTexture': {'index': 0},
      'metallicRoughnessTexture': {'index': 1},
    },
    'normalTexture': {'index': 2},
    'occlusionTexture': {'index': 1},
    'emissiveTexture': {'index': 3},
    'emissiveFactor': [.25, .25, .25],
  };
  double decode(int value) {
    final s = value / 255;
    return s <= .04045
        ? s / 12.92
        : math.pow((s + .055) / 1.055, 2.4).toDouble();
  }

  final expected = [
    for (var c = 0; c < 3; c++)
      encode(
        radiance(decode([128, 64, 32][c]), 0) + decode([64, 128, 0][c]) * .25,
      ),
    255,
  ];
  pixel(await render(pbrModel(material: mapped)), expected);
  pixel(
    await render(
      pbrModel(
        material: mapped,
        colorComponentType: 5123,
        colors: [
          for (var i = 0; i < 4; i++) ...[.25, 1, 0, .5],
        ],
      ),
    ),
    [
      for (var c = 0; c < 3; c++)
        encode(
          radiance(decode([128, 64, 32][c]) * [.25, 1, 0][c], 0) +
              decode([64, 128, 0][c]) * .25,
        ),
      255,
    ],
  );
  pixel(
    await render(
      pbrModel(
        material: {...mapped, 'alphaMode': 'MASK', 'alphaCutoff': .3},
        colors: [
          for (var i = 0; i < 4; i++) ...[1, 1, 1, .5],
        ],
      ),
    ),
    [0, 0, 0, 255],
  );
  pixel(
    await render(
      pbrModel(material: {...mapped, 'alphaMode': 'MASK', 'alphaCutoff': .6}),
    ),
    [0, 0, 0, 255],
  );
  pixel(
    await render(
      pbrModel(material: {...mapped, 'alphaMode': 'MASK', 'alphaCutoff': .4}),
    ),
    expected,
  );
  pixel(
    await render(
      pbrModel(
        material: mapped,
        unlit: true,
        light: {'type': 'directional', 'intensity': 1000},
      ),
    ),
    [128, 64, 32, 255],
  );
  pixel(
    await render(
      pbrModel(
        material: {
          'emissiveTexture': {'index': 3},
          'emissiveFactor': [1, 1, 1],
        },
        light: {'type': 'directional', 'intensity': 0},
      ),
    ),
    [64, 128, 0, 255],
  );
  final (energyA, energyB) = referenceDirectionalEnergy(1, 1);
  final diffuseBudget =
      1 - (.04 * energyA + energyB) * (1 + .04 * (1 / (energyA + energyB) - 1));
  for (final strength in [0.0, 1.0]) {
    pixel(
      await render(
        pbrModel(
          material: {
            'pbrMetallicRoughness': {
              'baseColorFactor': [.5, .5, .5, 1],
              'metallicFactor': 0,
            },
            'occlusionTexture': {'index': 1, 'strength': strength},
          },
          light: {'type': 'directional', 'intensity': 0},
        ),
        configure: (scene) {
          scene.add(HemisphereLight(groundColor: const Color3(1, 1, 1)));
        },
      ),
      strength == 1
          ? [0, 0, 0, 255]
          : [
              for (var c = 0; c < 3; c++) encode(.5 * diffuseBudget / math.pi),
              255,
            ],
    );
  }
  final normalMaterial = {
    'pbrMetallicRoughness': {
      'baseColorFactor': [.5, .5, .5, 1],
      'metallicFactor': 0,
    },
    'normalTexture': {'index': 4},
  };
  final node = {
    'rotation': [-math.sqrt(.5), 0, 0, math.sqrt(.5)],
  };
  final positive = await render(
    pbrModel(material: normalMaterial, lightNode: node),
  );
  final negative = await render(
    pbrModel(material: normalMaterial, lightNode: node, handedness: -1),
  );
  expect(positive[0], greaterThan(80));
  pixel(negative, [0, 0, 0, 255]);
  for (final flat in [false, true]) {
    final missing = editModel(
      pbrModel(material: normalMaterial, lightNode: node),
      (root) {
        final attributes =
            (root['meshes'] as List).first['primitives'][0]['attributes']
                as Map;
        if (flat) {
          attributes.remove('NORMAL');
        } else {
          attributes.remove('TANGENT');
        }
      },
    );
    // The fixture's V coordinate runs downward. MikkTSpace must generate -1
    // handedness, including after flat-normal expansion discards authored T.
    pixel(await render(missing, generatedTangents: true), negative);
  }
  await backend.render(
    FrameSubmission.capture(
      scene: Scene(),
      camera: camera,
      size: PhysicalSize(31, 31),
    ),
  );
  expect((await backend.resourceStats()).residentBytes, 0);
}
