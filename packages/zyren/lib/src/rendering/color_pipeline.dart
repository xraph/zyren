/// Curves map exposed linear HDR light into the display's [0, 1] range.
enum ToneMapping {
  linear,
  reinhard,
  acesFilmic;

  static const none = linear;
  static const aces = acesFilmic;
}

/// Enables linear RGBA16Float scene/effect color and terminal tone mapping.
/// Output remains SDR. Null at the view/submission retains the LDR profile.
final class ColorPipeline {
  final ToneMapping toneMapping;
  final double exposure;

  /// Scene coverage samples. Effects receive resolved single-sample color.
  final int sampleCount;
  ColorPipeline({
    this.toneMapping = ToneMapping.acesFilmic,
    this.exposure = 1,
    this.sampleCount = 1,
  }) {
    if (sampleCount != 1 && sampleCount != 4) {
      throw ArgumentError.value(sampleCount, 'sampleCount', 'Expected 1 or 4.');
    }
    if (!exposure.isFinite || exposure < 0 || exposure > 1e6) {
      throw ArgumentError.value(
        exposure,
        'exposure',
        'Expected finite [0, 1e6].',
      );
    }
  }
}
