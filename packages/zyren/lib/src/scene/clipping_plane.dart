part of 'scene.dart';

/// Retains points where `normal.dot(point) >= offset`, in world coordinates.
/// The constructor normalizes both the normal and offset by the normal length.
final class ClippingPlane {
  final Vec3 normal;
  final double offset;
  ClippingPlane._(this.normal, this.offset);
  factory ClippingPlane({required Vec3 normal, double offset = 0}) {
    final unit = normal.normalized();
    final distance = offset / normal.length;
    if (!distance.isFinite) {
      throw ArgumentError('Clipping plane offset must be finite.');
    }
    return ClippingPlane._(unit, distance);
  }

  double distanceTo(Vec3 point) => normal.dot(point) - offset;
  ClippingPlane get flipped => ClippingPlane._(-normal, -offset);
}
