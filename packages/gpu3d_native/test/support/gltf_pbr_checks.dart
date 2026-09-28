import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import '../../../gpu3d_gltf/test/support/pbr_fixture.dart';

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
  }) async {
    final assets = AssetScope(
      services: AssetServices(
        resolver: _Source(bytes),
        imageDecoder: const NativeImageDecoder(),
      ),
    );
    try {
      final model = await assets.load(Gltf.asset('pbr.glb')).result;
      expect(model.issues, isEmpty);
      final scene = Scene()
        ..background = const Color3(0, 0, 0)
        ..add(model.instantiate());
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

  // At N=L=V and roughness=1, GGX dielectric radiance is
  // base*.96/pi + .04/(4*pi); a metal has base/(4*pi).
  pixel(await render(pbrModel()), [110, 110, 110, 255]);
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
    [56, 56, 56, 255],
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
    [110, 110, 110, 255],
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
    [56, 56, 56, 255],
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
    [110, 110, 110, 255],
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

  int encode(double value) =>
      ((value <= .0031308
                  ? value * 12.92
                  : 1.055 * math.pow(value, 1 / 2.4) - .055) *
              255)
          .round();
  final expected = [
    for (var c = 0; c < 3; c++)
      encode(
        decode([128, 64, 32][c]) * .96 / math.pi +
            .04 / (4 * math.pi) +
            decode([64, 128, 0][c]) * .25,
      ),
    255,
  ];
  pixel(await render(pbrModel(material: mapped)), expected);
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
          : [for (var c = 0; c < 3; c++) encode(.5 * .96 / math.pi), 255],
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
  await backend.render(
    FrameSubmission.capture(
      scene: Scene(),
      camera: camera,
      size: PhysicalSize(31, 31),
    ),
  );
  expect((await backend.resourceStats()).residentBytes, 0);
}
