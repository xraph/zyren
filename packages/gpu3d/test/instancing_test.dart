import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';

Mat4 move(double x) => Mat4.compose(Vec3(x, 0, 0), Quat.identity, Vec3.one);

void main() {
  test(
    'instance transforms are atomic, immutable and revisioned independently of parents',
    () {
      final mesh = InstancedMesh(BoxGeometry(), UnlitMaterial(), count: 3);
      final first = mesh.captureInstances();
      expect(first.transforms.length, 3);
      mesh.setTransform(1, move(2));
      final second = mesh.captureInstances();
      expect(first.transforms[1], Mat4.identity());
      expect(second.transforms[1], move(2));
      expect(second.id, isNot(first.id));
      expect(second.logicalId, first.logicalId);
      expect(second.changesSince(first)!.single.first, 1);
      expect(second.changesSince(first)!.single.count, 1);
      final revision = mesh.revision;
      mesh.setTransform(1, move(2));
      expect(mesh.revision, revision);
      mesh.position = const Vec3(3, 0, 0);
      mesh.count = 1;
      expect(mesh.captureInstances(), same(second));
      expect(() => second.transforms.clear(), throwsUnsupportedError);
      expect(
        () => mesh.setTransforms(0, [
          move(4),
          Mat4.compose(Vec3.zero, Quat.identity, Vec3.zero),
        ]),
        throwsArgumentError,
      );
      expect(mesh.getTransform(0), Mat4.identity());
      expect(mesh.captureInstances(), same(second));
    },
  );

  test(
    'journals merge overlapping ranges and fall back after bounded history',
    () {
      final mesh = InstancedMesh(BoxGeometry(), UnlitMaterial(), count: 4);
      final first = mesh.captureInstances();
      mesh.setTransforms(0, [move(1), move(2)]);
      mesh.setTransforms(1, [move(3), move(4)]);
      final current = mesh.captureInstances();
      final change = current.changesSince(first)!.single;
      expect((change.first, change.count), (0, 3));
      for (var i = 0; i < 65; i++) {
        mesh.setTransform(0, move(i.toDouble()));
      }
      expect(mesh.captureInstances().changesSince(current), isNull);
      final sibling = InstancedMesh(mesh.geometry, mesh.material, count: 4);
      expect(
        mesh.captureInstances().changesSince(sibling.captureInstances()),
        isNull,
      );
    },
  );

  test('bounds include rotation, reflection and active prefix changes', () {
    final mesh = InstancedMesh(
      BoxGeometry(width: 2, height: 4, depth: 6),
      UnlitMaterial(),
      count: 2,
    );
    mesh.setTransform(
      0,
      Mat4.compose(
        const Vec3(10, 0, 0),
        Quat.axisAngle(const Vec3(0, 0, 1), math.pi / 2),
        const Vec3(-2, 1, .5),
      ),
    );
    mesh.setTransform(1, move(-10));
    expect(mesh.bounds.minimum.x, closeTo(-11, 1e-9));
    expect(mesh.bounds.maximum.x, closeTo(12, 1e-9));
    expect(mesh.bounds.maximum.y, closeTo(2, 1e-9));
    mesh.count = 1;
    expect(mesh.bounds.minimum.x, closeTo(8, 1e-9));
    expect(mesh.bounds.maximum.z, closeTo(1.5, 1e-9));
    mesh.count = 0;
    expect(mesh.bounds.isEmpty, isTrue);
    expect(mesh.bounds.contains(Vec3.zero), isFalse);
  });

  test(
    'instance admission rejects ranges, projective matrices and excessive capacity',
    () {
      final mesh = InstancedMesh(BoxGeometry(), UnlitMaterial(), count: 2);
      expect(() => mesh.count = 3, throwsRangeError);
      expect(() => mesh.setTransform(-1, move(0)), throwsRangeError);
      expect(() => mesh.setTransforms(1, [move(1), move(2)]), throwsRangeError);
      final projection = Mat4([
        1,
        0,
        0,
        .5,
        0,
        1,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        1,
      ]);
      expect(() => mesh.setTransform(0, projection), throwsArgumentError);
      expect(
        () => InstancedMesh(mesh.geometry, mesh.material, count: 100001),
        throwsRangeError,
      );
      expect(
        InstancedMesh(mesh.geometry, mesh.material, count: 0).bounds.isEmpty,
        isTrue,
      );
    },
  );
}
