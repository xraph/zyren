import '../math/vec3.dart';

/// Logical coordinates local to a viewport, independent of render resolution.
final class ViewportPoint {
  final double x, y;
  const ViewportPoint(this.x, this.y);
  Vec3 toNdc({required double logicalWidth, required double logicalHeight}) {
    if (!x.isFinite ||
        !y.isFinite ||
        !logicalWidth.isFinite ||
        !logicalHeight.isFinite ||
        logicalWidth <= 0 ||
        logicalHeight <= 0) {
      throw ArgumentError(
        'Logical coordinates and extent must be finite, with a positive extent.',
      );
    }
    return Vec3(2 * x / logicalWidth - 1, 1 - 2 * y / logicalHeight, 0);
  }
}
