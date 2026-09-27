import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart' as vm;

/// Immutable double-precision coordinates. Units belong to the owning scene.
final class Vec3 {
  final double x, y, z;
  const Vec3(this.x, this.y, this.z);
  static const zero = Vec3(0, 0, 0);
  static const one = Vec3(1, 1, 1);
  factory Vec3.fromVectorMath(vm.Vector3 value) =>
      Vec3(value.x, value.y, value.z);
  factory Vec3.array(List<double> values, [int offset = 0]) =>
      Vec3(values[offset], values[offset + 1], values[offset + 2]);
  bool get isFinite => x.isFinite && y.isFinite && z.isFinite;
  List<double> get storage => List.unmodifiable([x, y, z]);
  vm.Vector3 toVectorMath() => vm.Vector3(x, y, z);
  Vec3 operator +(Vec3 other) => Vec3(x + other.x, y + other.y, z + other.z);
  Vec3 operator -(Vec3 other) => Vec3(x - other.x, y - other.y, z - other.z);
  Vec3 operator -() => Vec3(-x, -y, -z);
  Vec3 operator *(double factor) => Vec3(x * factor, y * factor, z * factor);
  Vec3 operator /(double factor) => Vec3(x / factor, y / factor, z / factor);
  double dot(Vec3 other) => x * other.x + y * other.y + z * other.z;
  Vec3 cross(Vec3 other) => Vec3(
    y * other.z - z * other.y,
    z * other.x - x * other.z,
    x * other.y - y * other.x,
  );
  double get length2 => dot(this);
  double get length => math.sqrt(length2);
  double distanceTo(Vec3 other) => (this - other).length;
  Vec3 normalized() {
    final magnitude = length;
    if (!isFinite || !magnitude.isFinite || magnitude == 0) {
      throw ArgumentError('Cannot normalize a zero or nonfinite vector.');
    }
    return this / magnitude;
  }

  @override
  bool operator ==(Object other) =>
      other is Vec3 && x == other.x && y == other.y && z == other.z;
  @override
  int get hashCode => Object.hash(x, y, z);
  @override
  String toString() => 'Vec3($x, $y, $z)';
}
