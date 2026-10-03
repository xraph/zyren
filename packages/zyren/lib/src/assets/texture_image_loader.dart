import '../resources/texture_image.dart';
import '../resources/texture.dart' show MipmapAlphaFilter;
import 'asset_request.dart';
import 'asset_scope.dart';
import 'source_resolver.dart';
import 'texture_decoder.dart';

/// Loads a caller-local texture identity over shared decoded image storage.
/// Null [encoding] uses the configured ordinary image decoder.
final class TextureImageLoader extends AssetLoader<TextureImage> {
  final TextureEncoding? encoding;
  final bool generateMipmaps;
  final MipmapAlphaFilter mipmapAlphaFilter;
  const TextureImageLoader({
    this.encoding,
    this.generateMipmaps = false,
    this.mipmapAlphaFilter = MipmapAlphaFilter.independent,
  });
  @override
  Object get cacheKey => (encoding, generateMipmaps, mipmapAlphaFilter);
  @override
  Future<DecodedAsset<TextureImage>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    final TextureImageData data;
    if (encoding case final encoding?) {
      if (generateMipmaps) {
        throw ArgumentError('Encoded textures use their authored mip levels.');
      }
      data = await context.decodeTexture(source.bytes, encoding: encoding);
    } else {
      final image = await context.decodeImage(source.bytes);
      context.reserveDecodedBytes(image.size.width * image.size.height * 4);
      data = TextureImageData.fromImage(
        image,
        generateMipmaps: generateMipmaps,
        mipmapAlphaFilter: mipmapAlphaFilter,
      );
    }
    return DecodedAsset(
      create: () => TextureImage.fromData(data),
      release: (_) {},
      decodedBytes: data.levels.fold<int>(
        0,
        (sum, level) => sum + level.length,
      ),
    );
  }
}

abstract final class TextureAssets {
  static AssetRequest<TextureImage> uri(
    Uri uri, {
    String? version,
    TextureEncoding? encoding,
    bool generateMipmaps = false,
    MipmapAlphaFilter mipmapAlphaFilter = MipmapAlphaFilter.independent,
  }) => AssetRequest(
    uri: uri,
    version: version,
    loader: TextureImageLoader(
      encoding: encoding,
      generateMipmaps: generateMipmaps,
      mipmapAlphaFilter: mipmapAlphaFilter,
    ),
  );

  static AssetRequest<TextureImage> asset(
    String path, {
    String? version,
    TextureEncoding? encoding,
    bool generateMipmaps = false,
    MipmapAlphaFilter mipmapAlphaFilter = MipmapAlphaFilter.independent,
  }) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path.contains('\u0000') ||
        path
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw ArgumentError.value(
        path,
        'path',
        'Use a relative bundle path without traversal segments.',
      );
    }
    return uri(
      Uri(scheme: 'asset', host: '', path: '/$path'),
      version: version,
      encoding: encoding,
      generateMipmaps: generateMipmaps,
      mipmapAlphaFilter: mipmapAlphaFilter,
    );
  }
}
