import 'buffer.dart';

/// Type marker for a native GPU texture.
final class Texture {
  Texture._();
}

/// Alias for Flutter consumers, whose widget library also exports Texture.
typedef GpuTexture = Texture;

enum TextureFormat {
  rgba8Unorm(4, true),
  rgba8UnormSrgb(4, true),
  rgba16Float(8, true),
  rgba32Float(16, false),
  r32Float(4, false);

  final int bytesPerTexel;

  /// Whether the portable baseline permits linear sampling.
  final bool filterable;
  const TextureFormat(this.bytesPerTexel, this.filterable);
}

enum TextureDimension { d2, d3 }

/// Independent channels preserve hidden RGB. Weighted RGB uses alpha coverage
/// to prevent transparent colors from bleeding into smaller levels.
enum MipmapAlphaFilter { independent, weighted }

enum TextureUsage {
  sampled,
  renderAttachment,
  copySource,
  copyDestination,
  storage,
}

/// A typed texture. Float formats store linear data without color conversion.
/// Mip uploads contain tightly packed rows and depth slices, in that order.
final class TextureDescriptor extends ResourceDescriptor<Texture> {
  final int width, height, depth, mipLevels;
  final TextureDimension dimension;
  final TextureFormat format;
  final Set<TextureUsage> usage;
  TextureDescriptor({
    super.label = '',
    required this.width,
    required this.height,
    this.depth = 1,
    this.dimension = TextureDimension.d2,
    this.mipLevels = 1,
    this.format = TextureFormat.rgba8UnormSrgb,
    Set<TextureUsage> usage = const {
      TextureUsage.sampled,
      TextureUsage.copyDestination,
    },
  }) : usage = Set.unmodifiable(usage) {
    final maximum = dimension == TextureDimension.d3 ? 256 : 4096;
    if (width <= 0 ||
        height <= 0 ||
        depth <= 0 ||
        width > maximum ||
        height > maximum ||
        depth > maximum ||
        (dimension == TextureDimension.d2 && depth != 1)) {
      throw ArgumentError('Texture extent exceeds its dimension limits.');
    }
    var longest = width > height ? width : height;
    if (depth > longest) longest = depth;
    if (mipLevels < 1 || mipLevels > longest.bitLength) {
      throw ArgumentError.value(
        mipLevels,
        'mipLevels',
        'Mip count exceeds the texture extent.',
      );
    }
    if (usage.isEmpty) throw ArgumentError('Texture usage must not be empty.');
    if (dimension == TextureDimension.d3 &&
        usage.contains(TextureUsage.renderAttachment)) {
      throw ArgumentError('Volume textures cannot be color attachments.');
    }
    if (usage.contains(TextureUsage.storage) &&
        format == TextureFormat.rgba8UnormSrgb) {
      throw ArgumentError('Storage textures require a linear format.');
    }
    if (byteLength > 64 * 1024 * 1024) {
      throw ArgumentError('Texture exceeds 64 MiB.');
    }
  }
  int mipByteLength(int level) {
    RangeError.checkValueInInterval(level, 0, mipLevels - 1, 'mipLevel');
    final w = width >> level, h = height >> level, d = depth >> level;
    return (w == 0 ? 1 : w) *
        (h == 0 ? 1 : h) *
        (d == 0 ? 1 : d) *
        format.bytesPerTexel;
  }

  @override
  int get byteLength =>
      List.generate(mipLevels, mipByteLength).fold(0, (a, b) => a + b);
}
