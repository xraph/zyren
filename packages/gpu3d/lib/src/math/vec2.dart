import 'dart:math' as math;

/// Immutable double-precision coordinates, including UVs and lathe profiles.
final class Vec2 {
  final double x, y;
  const Vec2(this.x, this.y);
  static const zero = Vec2(0, 0);
  static const one = Vec2(1, 1);
  bool get isFinite => x.isFinite && y.isFinite;
  Vec2 operator +(Vec2 other) => Vec2(x + other.x, y + other.y);
  Vec2 operator -(Vec2 other) => Vec2(x - other.x, y - other.y);
  Vec2 operator -() => Vec2(-x, -y);
  Vec2 operator *(double scale) => Vec2(x * scale, y * scale);
  Vec2 operator /(double scale) => Vec2(x / scale, y / scale);
  double dot(Vec2 other) => x * other.x + y * other.y;
  double cross(Vec2 other) => x * other.y - y * other.x;
  double get length2 => dot(this);
  double get length => math.sqrt(length2);
  double distanceTo(Vec2 other) => (this - other).length;
  Vec2 normalized() {
    final size = length;
    if (!isFinite || !size.isFinite || size == 0) {
      throw ArgumentError('Cannot normalize a zero or nonfinite vector.');
    }
    return this / size;
  }

  @override
  bool operator ==(Object other) =>
      other is Vec2 && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(x, y);
  @override
  String toString() => 'Vec2($x, $y)';
}
