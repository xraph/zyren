import 'buffer.dart';

/// Type marker for a native GPU texture.
final class Texture {
  Texture._();
}

/// Alias for Flutter consumers, whose widget library also exports Texture.
typedef GpuTexture = Texture;

enum TextureFormat {
  rgba8Unorm,
  rgba8UnormSrgb,
  rgba16Float,
  bc7RgbaUnorm,
  bc7RgbaUnormSrgb,
  etc2Rgba8Unorm,
  etc2Rgba8UnormSrgb,
  astc4x4Unorm,
  astc4x4UnormSrgb,
  rgba32Float,
  r32Float;

  bool get isCompressed => index >= 3 && index <= 8;
  bool get filterable => this != rgba32Float && this != r32Float;
  int get bytesPerTexel => switch (this) {
    rgba16Float => 8,
    rgba32Float => 16,
    r32Float || rgba8Unorm || rgba8UnormSrgb => 4,
    _ => throw StateError('Compressed textures use blocks, not texels.'),
  };
  bool get isSrgb => this == rgba8UnormSrgb || (isCompressed && index.isEven);
  int get blockWidth => isCompressed ? 4 : 1;
  int get blockHeight => blockWidth;
  int get bytesPerBlock => isCompressed ? 16 : bytesPerTexel;

  /// Reinterprets the same bytes with the selected transfer function.
  TextureFormat withSrgb(bool srgb) {
    if (this == rgba16Float || this == rgba32Float || this == r32Float) {
      if (srgb) throw ArgumentError('Float textures have linear storage.');
      return this;
    }
    final linear = isSrgb ? index - 1 : index;
    return values[linear + (srgb ? 1 : 0)];
  }

  int levelByteLength(int width, int height) =>
      ((width + blockWidth - 1) ~/ blockWidth) *
      ((height + blockHeight - 1) ~/ blockHeight) *
      bytesPerBlock;
}

/// Independent channels preserve hidden RGB. Weighted RGB uses alpha coverage
/// to prevent transparent colors from bleeding into smaller levels.
enum TextureDimension { d2, d3 }

enum MipmapAlphaFilter { independent, weighted }

enum TextureUsage {
  sampled,
  renderAttachment,
  copySource,
  copyDestination,
  storage,
}

/// A two-dimensional RGBA texture. Float texels use four little-endian float16 values.
/// Mip uploads contain tightly packed rows and preserve alpha without conversion.
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
    if (usage.contains(TextureUsage.storage) && format.isSrgb) {
      throw ArgumentError('Storage textures require a linear format.');
    }
    if (format.isCompressed &&
        (dimension != TextureDimension.d2 ||
            width % 4 != 0 ||
            height % 4 != 0 ||
            usage.contains(TextureUsage.renderAttachment) ||
            usage.contains(TextureUsage.storage))) {
      throw ArgumentError(
        'Compressed textures require block-aligned base dimensions and sampled/copy usage.',
      );
    }
    if (dimension == TextureDimension.d3 &&
        usage.contains(TextureUsage.renderAttachment)) {
      throw ArgumentError('Volume textures cannot be color attachments.');
    }
    if (byteLength > 64 * 1024 * 1024) {
      throw ArgumentError('Texture exceeds 64 MiB.');
    }
  }
  int mipByteLength(int level) {
    RangeError.checkValueInInterval(level, 0, mipLevels - 1, 'mipLevel');
    final w = width >> level, h = height >> level, d = depth >> level;
    return format.levelByteLength(w == 0 ? 1 : w, h == 0 ? 1 : h) *
        (d == 0 ? 1 : d);
  }

  @override
  int get byteLength =>
      List.generate(mipLevels, mipByteLength).fold(0, (a, b) => a + b);
}
