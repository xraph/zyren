import 'dart:typed_data';
import 'texture.dart';
import '../rendering/frame_output.dart';

enum TextureWrap { clampToEdge, repeat, mirroredRepeat }

enum TextureFilter { nearest, linear }

/// Sampling is independent of image storage and may vary between materials.
final class SamplerDescriptor {
  final TextureWrap wrapU, wrapV;
  final TextureFilter minFilter, magFilter, mipFilter;
  const SamplerDescriptor({
    this.wrapU = TextureWrap.clampToEdge,
    this.wrapV = TextureWrap.clampToEdge,
    this.minFilter = TextureFilter.linear,
    this.magFilter = TextureFilter.linear,
    this.mipFilter = TextureFilter.linear,
  });
  List<int> toPacket() => [
    wrapU.index,
    wrapV.index,
    minFilter.index,
    magFilter.index,
    mipFilter.index,
  ];
}

/// Immutable, tightly packed RGBA image levels, with a top-left pixel origin.
/// Creating an image allocates CPU storage. Each native device uploads on demand.
final class TextureImage {
  static int _nextId = 1;
  final int id = _nextId++;
  final TextureDescriptor descriptor;

  /// CPU-provided levels. Generated lower levels stay on the GPU.
  final List<Uint8List> levels;

  /// Whether the native device generates the full chain from level zero.
  final bool generatesMipmaps;
  final MipmapAlphaFilter mipmapAlphaFilter;
  factory TextureImage.fromImage(
    ImageData image, {
    bool generateMipmaps = false,
    MipmapAlphaFilter mipmapAlphaFilter = MipmapAlphaFilter.independent,
  }) {
    if (image.format != PixelFormat.rgba8 ||
        image.alphaMode == AlphaMode.premultiplied) {
      throw UnsupportedError(
        'Color textures require straight or opaque RGBA8 pixels.',
      );
    }
    final descriptor = TextureDescriptor(
      width: image.size.width,
      height: image.size.height,
      mipLevels: generateMipmaps
          ? (image.size.width > image.size.height
                    ? image.size.width
                    : image.size.height)
                .bitLength
          : 1,
      format: image.colorSpace == ColorSpace.srgb
          ? TextureFormat.rgba8UnormSrgb
          : TextureFormat.rgba8Unorm,
    );
    final pixels = Uint8List(descriptor.mipByteLength(0));
    final rowBytes = image.size.width * 4;
    for (var y = 0; y < image.size.height; y++) {
      pixels.setRange(
        y * rowBytes,
        (y + 1) * rowBytes,
        image.pixels,
        y * image.rowStride,
      );
    }
    return TextureImage._(
      descriptor,
      List.unmodifiable([pixels.asUnmodifiableView()]),
      generateMipmaps,
      mipmapAlphaFilter,
    );
  }
  factory TextureImage.rgba({
    required int width,
    required int height,
    required Uint8List pixels,
    List<Uint8List> mipmaps = const [],
    bool generateMipmaps = false,
    MipmapAlphaFilter mipmapAlphaFilter = MipmapAlphaFilter.independent,
    TextureFormat format = TextureFormat.rgba8UnormSrgb,
  }) {
    if (generateMipmaps && mipmaps.isNotEmpty) {
      throw ArgumentError('Choose supplied mipmaps or native generation.');
    }
    final descriptor = TextureDescriptor(
      width: width,
      height: height,
      mipLevels: generateMipmaps
          ? (width > height ? width : height).bitLength
          : mipmaps.length + 1,
      format: format,
    );
    final sources = [pixels, ...mipmaps];
    for (var i = 0; i < sources.length; i++) {
      if (sources[i].length != descriptor.mipByteLength(i)) {
        throw ArgumentError('Mip $i must contain tightly packed RGBA pixels.');
      }
    }
    return TextureImage._(
      descriptor,
      List.unmodifiable([
        for (final source in sources)
          Uint8List.fromList(source).asUnmodifiableView(),
      ]),
      generateMipmaps,
      mipmapAlphaFilter,
    );
  }
  TextureImage._(
    this.descriptor,
    this.levels,
    this.generatesMipmaps,
    this.mipmapAlphaFilter,
  );
}

/// Color image binding. UV (0, 0) addresses the image's top-left corner.
final class TextureMap {
  final TextureImage image;
  final SamplerDescriptor sampler;
  final int uvSet;
  TextureMap({
    required this.image,
    this.sampler = const SamplerDescriptor(),
    this.uvSet = 0,
  }) {
    RangeError.checkValueInInterval(uvSet, 0, 1, 'uvSet');
  }
  List<int> toPacket() => [image.id, uvSet, ...sampler.toPacket()];
}
