import 'buffer.dart';

/// Type marker for a native GPU texture.
final class Texture {
  Texture._();
}

/// Alias for Flutter consumers, whose widget library also exports Texture.
typedef GpuTexture = Texture;

enum TextureFormat { rgba8Unorm, rgba8UnormSrgb }

/// Independent channels preserve hidden RGB. Weighted RGB uses alpha coverage
/// to prevent transparent colors from bleeding into smaller levels.
enum MipmapAlphaFilter { independent, weighted }

enum TextureUsage { sampled, renderAttachment, copySource, copyDestination }

/// A two-dimensional RGBA8 texture. The format determines its color encoding.
/// Mip uploads contain tightly packed rows and preserve alpha without conversion.
final class TextureDescriptor extends ResourceDescriptor<Texture> {
  final int width, height, mipLevels;
  final TextureFormat format;
  final Set<TextureUsage> usage;
  TextureDescriptor({
    super.label = '',
    required this.width,
    required this.height,
    this.mipLevels = 1,
    this.format = TextureFormat.rgba8UnormSrgb,
    Set<TextureUsage> usage = const {
      TextureUsage.sampled,
      TextureUsage.copyDestination,
    },
  }) : usage = Set.unmodifiable(usage) {
    if (width <= 0 || height <= 0 || width > 4096 || height > 4096) {
      throw ArgumentError('Texture dimensions must be in [1, 4096].');
    }
    if (mipLevels < 1 ||
        mipLevels > (width > height ? width : height).bitLength) {
      throw ArgumentError.value(
        mipLevels,
        'mipLevels',
        'Mip count exceeds the texture extent.',
      );
    }
    if (usage.isEmpty) throw ArgumentError('Texture usage must not be empty.');
    if (byteLength > 64 * 1024 * 1024) {
      throw ArgumentError('Texture exceeds 64 MiB.');
    }
  }
  int mipByteLength(int level) {
    RangeError.checkValueInInterval(level, 0, mipLevels - 1, 'mipLevel');
    final w = width >> level, h = height >> level;
    return (w == 0 ? 1 : w) * (h == 0 ? 1 : h) * 4;
  }

  @override
  int get byteLength =>
      List.generate(mipLevels, mipByteLength).fold(0, (a, b) => a + b);
}
