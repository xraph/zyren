/// Curves map exposed linear HDR light into the display's [0, 1] range.
enum ToneMapping { linear, reinhard, acesFilmic }

/// Enables linear RGBA16Float scene/effect color and terminal tone mapping.
/// Output remains SDR. Null at the view/submission retains the LDR profile.
final class ColorPipeline {
  final ToneMapping toneMapping;
  final double exposure;
  ColorPipeline({
    this.toneMapping = ToneMapping.acesFilmic,
    this.exposure = 1,
  }) {
    if (!exposure.isFinite || exposure < 0 || exposure > 1e6) {
      throw ArgumentError.value(
        exposure,
        'exposure',
        'Expected finite [0, 1e6].',
      );
    }
  }
}
