import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'asset_cache_test.dart' show Resolver;

class ImageCodec implements ImageDecoder {
  int decodes = 0;
  @override
  Future<ImageData> decode(
    Uint8List bytes, {
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async {
    decodes++;
    return ImageData(
      size: PhysicalSize(2, 1),
      pixels: Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255]),
    );
  }
}

class TextureCodec implements TextureDecoder {
  int decodes = 0;
  @override
  Set<TextureEncoding> get encodings => {TextureEncoding.ktx2Basis};
  @override
  Future<TextureImageData> decode(
    Uint8List bytes, {
    required TextureEncoding encoding,
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async {
    decodes++;
    return TextureImageData.compressed(
      width: 4,
      height: 4,
      format: TextureFormat.bc7RgbaUnorm,
      blocks: Uint8List(16),
      mipmaps: [Uint8List(16)],
    );
  }
}

void main() {
  test(
    'ordinary texture recipes retain pixel storage and fresh image identities',
    () async {
      final codec = ImageCodec(), cache = AssetCache();
      final scope = AssetScope(
        services: AssetServices(resolver: Resolver(), imageDecoder: codec),
        cache: cache,
      );
      final uri = Uri.parse('memory:/image');
      final first = await scope
          .load(TextureAssets.uri(uri, generateMipmaps: true))
          .result;
      final second = await scope
          .load(TextureAssets.uri(uri, generateMipmaps: true))
          .result;
      expect(first.id, isNot(second.id));
      expect(first.data, same(second.data));
      expect(first.generatesMipmaps, isTrue);
      expect(first.descriptor.mipLevels, 2);
      expect(cache.decodedBytes, 8);
      expect(codec.decodes, 1);
      cache.dispose();
      await scope.close();
      expect(first.levels.first, [255, 0, 0, 255, 0, 255, 0, 255]);
    },
  );

  test(
    'encoded textures preserve authored mips and use the texture decoder',
    () async {
      final codec = TextureCodec(), cache = AssetCache();
      final scope = AssetScope(
        services: AssetServices(resolver: Resolver(), textureDecoder: codec),
        cache: cache,
      );
      final value = await scope
          .load(
            TextureAssets.uri(
              Uri.parse('memory:/texture'),
              encoding: TextureEncoding.ktx2Basis,
            ),
          )
          .result;
      expect(value.descriptor.format, TextureFormat.bc7RgbaUnorm);
      expect(value.levels, hasLength(2));
      expect(value.generatesMipmaps, isFalse);
      expect(codec.decodes, 1);
      expect(cache.decodedBytes, 32);
      await expectLater(
        scope
            .load(
              TextureAssets.uri(
                Uri.parse('memory:/invalid'),
                encoding: TextureEncoding.ktx2Basis,
                generateMipmaps: true,
              ),
            )
            .result,
        throwsA(isA<AssetLoadException>()),
      );
      expect(cache.length, 1);
      cache.dispose();
      await scope.close();
    },
  );

  test(
    'texture request helpers compare decode options and reject bundle traversal',
    () {
      expect(
        TextureAssets.asset('images/a.png'),
        TextureAssets.asset('images/a.png'),
      );
      expect(
        TextureAssets.asset('images/a.png').uri,
        Uri.parse('asset:///images/a.png'),
      );
      expect(
        TextureAssets.asset('images/a.png', generateMipmaps: true),
        isNot(TextureAssets.asset('images/a.png')),
      );
      for (final path in [
        '',
        '/a',
        '../a',
        'a/../b',
        'a//b',
        'a\\b',
        'a\u0000',
      ]) {
        expect(() => TextureAssets.asset(path), throwsArgumentError);
      }
    },
  );
}
