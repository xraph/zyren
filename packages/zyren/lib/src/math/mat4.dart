import 'package:vector_math/vector_math_64.dart' as vm;
import 'quat.dart';
import 'vec3.dart';

/// Immutable column-major matrix. Interop always returns independent storage.
final class Mat4 {
  final List<double> storage;
  Mat4(Iterable<double> values) : storage = List.unmodifiable(values) {
    if (storage.length != 16 || storage.any((v) => !v.isFinite)) {
      throw ArgumentError('A matrix requires 16 finite column-major values.');
    }
  }
  factory Mat4.identity() => Mat4(vm.Matrix4.identity().storage);
  factory Mat4.fromVectorMath(vm.Matrix4 value) => Mat4(value.storage);
  factory Mat4.compose(Vec3 position, Quat rotation, Vec3 scale) =>
      Mat4.fromVectorMath(
        vm.Matrix4.compose(
          position.toVectorMath(),
          rotation.toVectorMath(),
          scale.toVectorMath(),
        ),
      );
  vm.Matrix4 toVectorMath() => vm.Matrix4.fromList(storage);
  Mat4 operator *(Mat4 other) =>
      Mat4.fromVectorMath(toVectorMath() * other.toVectorMath());
  Mat4 inverted() {
    final inverse = toVectorMath();
    final determinant = inverse.invert();
    if (!determinant.isFinite || determinant == 0) {
      throw ArgumentError('Matrix is singular.');
    }
    return Mat4.fromVectorMath(inverse);
  }

  @override
  bool operator ==(Object other) =>
      other is Mat4 &&
      Iterable<int>.generate(16).every((i) => storage[i] == other.storage[i]);
  @override
  int get hashCode => Object.hashAll(storage);
}
