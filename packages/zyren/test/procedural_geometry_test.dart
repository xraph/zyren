import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

void checkSurface(BufferGeometry mesh) {
  expect(mesh.uv0!.length, mesh.vertexCount * 2);
  for (var i = 0; i < mesh.vertexCount; i++) {
    expect(Vec3.array(mesh.normals, i * 3).length, closeTo(1, 1e-6));
    expect(Vec3.array(mesh.positions, i * 3).isFinite, isTrue);
  }
  for (var i = 0; i < mesh.indices.length; i += 3) {
    final a = mesh.indices[i], b = mesh.indices[i + 1], c = mesh.indices[i + 2];
    final pa = Vec3.array(mesh.positions, a * 3),
        pb = Vec3.array(mesh.positions, b * 3),
        pc = Vec3.array(mesh.positions, c * 3);
    final normal =
        Vec3.array(mesh.normals, a * 3) +
        Vec3.array(mesh.normals, b * 3) +
        Vec3.array(mesh.normals, c * 3);
    expect(
      (pb - pa).cross(pc - pa).dot(normal),
      greaterThan(0),
      reason: 'reversed/degenerate triangle $i',
    );
  }
}

void main() {
  test('lathe poles follow the slope of their straight flank', () {
    for (final points in [
      [const Vec2(0, -1), const Vec2(1, 1)],
      [const Vec2(1, -1), const Vec2(0, 1)],
    ]) {
      final cone = LatheGeometry(points, segments: 8);
      checkSurface(cone);
      for (var i = 0; i <= 8; i++) {
        final bottom = Vec3.array(cone.normals, i * 3);
        final top = Vec3.array(cone.normals, (9 + i) * 3);
        final t = math.pi * 2 * i / 8;
        final tangent = Vec3(
          math.cos(t) * (points[1].x - points[0].x),
          2,
          math.sin(t) * (points[1].x - points[0].x),
        );
        expect(bottom.distanceTo(top), lessThan(1e-6));
        expect(bottom.dot(tangent), closeTo(0, 1e-6));
      }
    }
  });
  test(
    'procedural surfaces have outward winding, unit normals and UV seams',
    () {
      for (final geometry in <BufferGeometry>[
        CircleGeometry(),
        RingGeometry(),
        CylinderGeometry(),
        ConeGeometry(),
        TorusGeometry(),
        CapsuleGeometry(),
        LatheGeometry([
          const Vec2(.3, -1),
          const Vec2(1, 0),
          const Vec2(.5, 1),
        ]),
      ]) {
        checkSurface(geometry);
      }
    },
  );
  test(
    'cylinder dimensions, open caps and cone apex match analytic bounds',
    () {
      final closed = CylinderGeometry(
        radiusTop: 2,
        radiusBottom: 1,
        height: 4,
        radialSegments: 8,
        heightSegments: 2,
      );
      final open = CylinderGeometry(
        radiusTop: 2,
        radiusBottom: 1,
        height: 4,
        radialSegments: 8,
        heightSegments: 2,
        openEnded: true,
      );
      expect(closed.indices.length - open.indices.length, 8 * 2 * 3);
      expect(closed.capture().bounds.minimum, const Vec3(-2, -2, -2));
      expect(closed.capture().bounds.maximum, const Vec3(2, 2, 2));
      final cone = ConeGeometry(radius: 2, height: 4, radialSegments: 8);
      expect(cone.indices.length, 8 * 2 * 3);
      checkSurface(cone);
    },
  );
  test('ring holes and partial arcs preserve their plane and bounds', () {
    final ring = RingGeometry(
      innerRadius: .5,
      outerRadius: 1,
      thetaSegments: 8,
    );
    for (var i = 0; i < ring.vertexCount; i++) {
      final point = Vec3.array(ring.positions, i * 3);
      expect(point.z, 0);
      expect(point.length, inInclusiveRange(.499999, 1.000001));
    }
    final quarter = CircleGeometry(
      radius: 2,
      segments: 8,
      thetaLength: math.pi / 2,
    );
    expect(quarter.capture().bounds.minimum, Vec3.zero);
    expect(quarter.capture().bounds.maximum, const Vec3(2, 2, 0));
  });
  test('capsule and torus bounds include their radial extent', () {
    final capsule = CapsuleGeometry(
      radius: .5,
      length: 2,
      capSegments: 8,
      radialSegments: 16,
    );
    expect(capsule.capture().bounds.minimum, const Vec3(-.5, -1.5, -.5));
    expect(capsule.capture().bounds.maximum, const Vec3(.5, 1.5, .5));
    for (var i = 0; i < capsule.vertexCount; i++) {
      final p = Vec3.array(capsule.positions, i * 3);
      final expected = (p - Vec3(0, p.y.clamp(-1.0, 1.0), 0)).normalized();
      expect(
        Vec3.array(capsule.normals, i * 3).distanceTo(expected),
        lessThan(1e-6),
      );
    }

    final torus = TorusGeometry(
      radius: 2,
      tube: .5,
      radialSegments: 8,
      tubularSegments: 16,
    );
    expect(torus.capture().bounds.minimum, const Vec3(-2.5, -2.5, -.5));
    expect(torus.capture().bounds.maximum, const Vec3(2.5, 2.5, .5));
    checkSurface(CapsuleGeometry(length: 0));
  });
  test('invalid and excessive tessellation reject before allocation', () {
    expect(
      () => CylinderGeometry(radialSegments: 1000000),
      throwsArgumentError,
    );
    expect(
      () => CylinderGeometry(radiusTop: 0, radiusBottom: 0),
      throwsArgumentError,
    );
    expect(() => TorusGeometry(tube: double.nan), throwsArgumentError);
    expect(
      () => RingGeometry(innerRadius: 2, outerRadius: 1),
      throwsArgumentError,
    );
    expect(() => CircleGeometry(thetaLength: 0), throwsArgumentError);
    expect(() => LatheGeometry([Vec2.zero, Vec2.zero]), throwsArgumentError);
    expect(() => CapsuleGeometry(length: -1), throwsArgumentError);
  });
}
