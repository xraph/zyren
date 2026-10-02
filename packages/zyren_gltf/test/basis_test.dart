import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'geometry_model_test.dart' show onlyMesh;
import 'image_model_test.dart' show Images, ImageSources;
import 'support/fixtures.dart';

const magic = [171, 75, 84, 88, 32, 50, 48, 187, 13, 10, 26, 10];

class Textures implements TextureDecoder {
  int calls = 0;
  bool linear = false, onlyBase = false, compressed = false;
  @override
  Set<TextureEncoding> get encodings => const {TextureEncoding.ktx2Basis};
  @override
  Future<TextureImageData> decode(
    Uint8List bytes, {
    required TextureEncoding encoding,
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async {
    calls++;
    if (compressed) {
      return TextureImageData.compressed(
        width: 4,
        height: 4,
        blocks: Uint8List(16),
        mipmaps: onlyBase ? [] : [Uint8List(16), Uint8List(16)],
        format: linear
            ? TextureFormat.bc7RgbaUnorm
            : TextureFormat.bc7RgbaUnormSrgb,
      );
    }
    return TextureImageData.rgba(
      width: 4,
      height: 4,
      pixels: Uint8List(64),
      mipmaps: onlyBase ? [] : [Uint8List(16), Uint8List(4)],
      format: linear ? TextureFormat.rgba8Unorm : TextureFormat.rgba8UnormSrgb,
    );
  }
}

Uint8List model({
  bool required = true,
  bool fallback = false,
  int filter = 9987,
  void Function(Map<String, Object?>)? edit,
}) => editModel(texturedModel(minFilter: filter), (root) {
  root['extensionsUsed'] = ['KHR_materials_unlit', 'KHR_texture_basisu'];
  root['extensionsRequired'] = [
    'KHR_materials_unlit',
    if (required) 'KHR_texture_basisu',
  ];
  root['images'] = [
    {
      'uri': 'data:image/ktx2;base64,${base64Encode(magic)}',
      'mimeType': 'image/ktx2',
    },
    {'uri': 'data:image/png;base64,$cornersPng'},
  ];
  root['textures'] = [
    {
      'sampler': 0,
      if (fallback) 'source': 1,
      'extensions': {
        'KHR_texture_basisu': {'source': 0},
      },
    },
  ];
  edit?.call(root);
});
Matcher error(AssetLoadError code) =>
    isA<AssetLoadException>().having((e) => e.code, 'code', code);
Future<ModelAsset> load(Uint8List bytes, {Textures? textures, Images? images}) {
  final scope = AssetScope(
    services: AssetServices(
      resolver: ImageSources(bytes),
      textureDecoder: textures,
      imageDecoder: images,
    ),
  );
  addTearDown(scope.close);
  return scope.load(Gltf.asset('model.glb')).result;
}

void main() {
  test(
    'compressed Basis storage retains color, mip selection and base-only sampling',
    () async {
      for (final filter in [9728, 9987]) {
        for (final baseOnly in [false, true]) {
          final asset = await load(
            model(filter: filter),
            textures: Textures()
              ..compressed = true
              ..onlyBase = baseOnly,
          );
          final image = onlyMesh(asset).material.colorMap!.image;
          expect(image.descriptor.format, TextureFormat.bc7RgbaUnormSrgb);
          expect(image.levels.length, filter == 9728 || baseOnly ? 1 : 3);
          expect(image.generatesMipmaps, false);
          expect(image.descriptor.byteLength, image.levels.length * 16);
        }
      }
      await expectLater(
        load(
          model(),
          textures: Textures()
            ..compressed = true
            ..linear = true,
        ),
        throwsA(error(AssetLoadError.invalidData)),
      );
    },
  );
  test('linear Basis data maps keep linear storage', () async {
    final asset = await load(
      model(
        edit: (root) {
          root['materials'] = [
            {
              'pbrMetallicRoughness': {
                'metallicRoughnessTexture': {'index': 0},
              },
            },
          ];
        },
      ),
      textures: Textures()..linear = true,
    );
    final material = onlyMesh(asset).material as StandardMaterial;
    expect(
      material.metallicRoughnessMap!.image.descriptor.format,
      TextureFormat.rgba8Unorm,
    );
  });
  test('Basis dispatch preserves authored mips and sampler choices', () async {
    for (final filter in [9728, 9987]) {
      final codec = Textures();
      final asset = await load(model(filter: filter), textures: codec);
      expect(asset.issues, isEmpty);
      final map = onlyMesh(asset).material.colorMap!;
      expect(map.image.levels.length, filter == 9728 ? 1 : 3);
      expect(map.image.generatesMipmaps, isFalse);
      expect(codec.calls, 1);
    }
    final asset = await load(model(), textures: Textures()..onlyBase = true);
    expect(onlyMesh(asset).material.colorMap!.image.generatesMipmaps, isTrue);
  });
  test(
    'required codec fails early while optional extension uses ordinary fallback',
    () async {
      await expectLater(
        load(model()),
        throwsA(error(AssetLoadError.unsupportedFeature)),
      );
      final png = Images(), codec = Textures();
      await load(model(required: false, fallback: true), images: png);
      expect(png.calls, 1);
      await load(
        model(required: false, fallback: true),
        images: png,
        textures: codec,
      );
      expect(png.calls, 1);
      expect(codec.calls, 1);
      await expectLater(
        load(model(required: false), textures: codec),
        throwsA(error(AssetLoadError.invalidData)),
      );
    },
  );
  test(
    'Basis sources validate references, MIME and material transfer',
    () async {
      for (final edit in <void Function(Map<String, Object?>)>[
        (r) =>
            (r['textures'] as List)
                    .first['extensions']['KHR_texture_basisu']['source'] =
                99,
        (r) => (r['images'] as List).first['mimeType'] = 'image/png',
        (r) => (r['images'] as List).first['uri'] =
            'data:image/ktx2;base64,$cornersPng',
      ]) {
        await expectLater(
          load(model(edit: edit), textures: Textures()),
          throwsA(error(AssetLoadError.invalidData)),
        );
      }
      await expectLater(
        load(model(), textures: Textures()..linear = true),
        throwsA(error(AssetLoadError.invalidData)),
      );
    },
  );
}
