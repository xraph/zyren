import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:zyren/zyren.dart';

class _ComputedPosition extends Object3D {
  Vec3 computed = Vec3.zero;
  @override
  Vec3 get position => computed;
}

void main() {
  test('unchanged poses reuse immutable local transforms', () {
    final object = Group();
    final original = object.localMatrix;
    expect(object.localMatrix, same(original));
    object.position = Vec3.zero;
    object.scale = Vec3.one;
    object.quaternion = Quat.identity;
    object.visible = false;
    object.add(Group()..position = const Vec3(1, 2, 3));
    expect(object.localMatrix, same(original));
    expect(() => original.storage[12] = 9, throwsUnsupportedError);
    original.toVectorMath().storage[12] = 9;
    expect(object.localMatrix.storage[12], 0);
  });

  test('pose changes replace the cache without changing older snapshots', () {
    final object = Group();
    final original = object.localMatrix;
    object.position = const Vec3(3, 4, 5);
    final translated = object.localMatrix;
    expect(translated.storage.sublist(12, 15), [3, 4, 5]);
    object.scale = const Vec3(2, 3, 4);
    final scaled = object.localMatrix;
    expect(
      [scaled.storage[0], scaled.storage[5], scaled.storage[10]],
      [2, 3, 4],
    );
    object.rotateZ(math.pi / 2);
    final rotated = object.localMatrix;
    expect(rotated.storage[0], closeTo(0, 1e-12));
    expect(rotated.storage[1], closeTo(2, 1e-12));
    expect(rotated.storage[4], closeTo(-3, 1e-12));
    expect(object.localMatrix, same(rotated));
    expect(original, Mat4.identity());
    expect(translated.storage[0], 1);
    expect(scaled.storage[0], 2);
  });

  test('parent motion and reparenting update world transforms', () {
    final parent = Group()..position = const Vec3(100, 0, 0);
    final child = parent.add(Group()..position = const Vec3(2, 0, 0));
    final local = child.localMatrix;
    expect(child.worldMatrix.storage[12], 102);
    parent.position = const Vec3(200, 0, 0);
    expect(child.localMatrix, same(local));
    expect(child.worldMatrix.storage[12], 202);
    final other = Group()..position = const Vec3(-100, 0, 0);
    other.add(child);
    expect(child.localMatrix, same(local));
    expect(child.worldMatrix.storage[12], -98);
  });

  test('computed transform getters cannot leave cached poses stale', () {
    final object = _ComputedPosition();
    final original = object.localMatrix;
    object.computed = const Vec3(7, 8, 9);
    expect(object.localMatrix.storage.sublist(12, 15), [7, 8, 9]);
    expect(object.localMatrix, isNot(same(original)));
  });
}
