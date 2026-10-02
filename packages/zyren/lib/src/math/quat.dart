import 'package:vector_math/vector_math_64.dart' as vm;
import 'vec3.dart';

/// Immutable quaternion in x, y, z, w order. Scene setters normalize rotations.
final class Quat {
  final double x, y, z, w;
  const Quat(this.x, this.y, this.z, this.w);
  static const identity = Quat(0, 0, 0, 1);
  factory Quat.fromVectorMath(vm.Quaternion value) =>
      Quat(value.x, value.y, value.z, value.w);
  factory Quat.axisAngle(Vec3 axis, double radians) {
    if (!radians.isFinite) throw ArgumentError.value(radians, 'radians');
    return Quat.fromVectorMath(
      vm.Quaternion.axisAngle(axis.normalized().toVectorMath(), radians),
    );
  }
  bool get isFinite => x.isFinite && y.isFinite && z.isFinite && w.isFinite;
  vm.Quaternion toVectorMath() => vm.Quaternion(x, y, z, w);
  Quat normalized() {
    final q = toVectorMath();
    if (!isFinite || !q.length2.isFinite || q.length2 < 1e-30) {
      throw ArgumentError('Rotation must be finite and nonzero.');
    }
    // Re-normalizing a unit quaternion can oscillate between adjacent doubles.
    // Preserve already-normalized poses so assignment and history are stable.
    if ((q.length2 - 1).abs() <= 1e-15) return this;
    q.normalize();
    return Quat.fromVectorMath(q);
  }

  Quat operator *(Quat other) =>
      Quat.fromVectorMath(toVectorMath() * other.toVectorMath());
  Vec3 rotate(Vec3 value) => Vec3.fromVectorMath(
    normalized().toVectorMath().asRotationMatrix().transformed(
      value.toVectorMath(),
    ),
  );
  @override
  bool operator ==(Object other) =>
      other is Quat &&
      x == other.x &&
      y == other.y &&
      z == other.z &&
      w == other.w;
  @override
  int get hashCode => Object.hash(x, y, z, w);
}
