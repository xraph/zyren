import 'dart:math' as math;

/// Linear RGB channels in [0, 1].
final class Color3 {
  final double r, g, b;
  const Color3(this.r, this.g, this.b);
  factory Color3.hex(int rgb) {
    double linear(int channel) {
      final c = channel / 255;
      return c <= .04045
          ? c / 12.92
          : math.pow((c + .055) / 1.055, 2.4).toDouble();
    }

    return Color3(
      linear((rgb >> 16) & 255),
      linear((rgb >> 8) & 255),
      linear(rgb & 255),
    );
  }
  @override
  bool operator ==(Object other) =>
      other is Color3 && r == other.r && g == other.g && b == other.b;
  @override
  int get hashCode => Object.hash(r, g, b);

  /// Validates linear channels for the consuming material or light profile.
  List<double> toList({double maxChannel = 1}) {
    if (!maxChannel.isFinite || maxChannel <= 0) {
      throw ArgumentError.value(maxChannel, 'maxChannel');
    }
    final values = [r, g, b];
    if (values.any((v) => !v.isFinite || v < 0 || v > maxChannel)) {
      throw ArgumentError('RGB channels must be in [0, $maxChannel].');
    }
    return values;
  }
}
