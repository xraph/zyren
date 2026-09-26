import 'package:vector_math/vector_math_64.dart' show Vector4;
import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';

void main() {
  test('reparenting preserves a tree and rejects cycles', () {
    final root = Scene(), a = Object3D(), b = Object3D();
    root.add(a);
    a.add(b);
    expect(() => b.add(root), throwsArgumentError);
    root.add(b);
    expect(a.children, isEmpty);
    expect(b.parent, same(root));
    root.remove(b);
    expect(b.parent, isNull);
  });
  test('composes parent transforms before subtracting the camera origin', () {
    final scene = Scene(),
        parent = Object3D()..position = const Vec3(6378137, 0, 0);
    final mesh = Mesh(BoxGeometry(), DiffuseMaterial())
      ..position = const Vec3(.001, 0, 0);
    scene.add(parent);
    parent.add(mesh);
    final camera = PerspectiveCamera(
      position: Vec3(6378137, 0, 5),
      target: Vec3(6378137, 0, 0),
    );
    final frame = scene.snapshot(camera, 1);
    final model =
        ((frame['meshes'] as List).single as Map)['model'] as List<double>;
    expect(model[12], closeTo(.001, 1e-9));
    expect(model[14], -5);
    expect(frame['geometries'], hasLength(1));
    expect(
      scene.snapshot(camera, 1, uploaded: {mesh.geometry.id})['geometries'],
      isEmpty,
    );
    parent.visible = false;
    expect(scene.snapshot(camera, 1)['meshes'], isEmpty);
  });
  test('native perspective maps near and far to zero and one', () {
    final camera = PerspectiveCamera(
      position: Vec3.zero,
      target: Vec3(0, 0, -1),
      near: 1,
      far: 100,
    );
    final vp = camera.viewProjection(1).toVectorMath();
    final near = vp * Vector4(0, 0, -1, 1), far = vp * Vector4(0, 0, -100, 1);
    expect(near.z / near.w, closeTo(0, 1e-12));
    expect(far.z / far.w, closeTo(1, 1e-12));
    camera.target = Vec3.zero;
    expect(() => camera.viewProjection(1), throwsArgumentError);
  });
  test('sphere indices have outward winding and immutable storage', () {
    final sphere = SphereGeometry(widthSegments: 12, heightSegments: 6);
    for (var i = 0; i < sphere.indices.length; i += 3) {
      Vec3 vertex(int index) =>
          Vec3.array(sphere.positions, sphere.indices[index] * 3);
      final a = vertex(i), b = vertex(i + 1), c = vertex(i + 2);
      expect((b - a).cross(c - a).dot(a), greaterThan(0));
    }
    expect(() => sphere.positions[0] = 3, throwsUnsupportedError);
    expect(() => SphereGeometry(radius: double.nan), throwsArgumentError);
    expect(
      Color3.hex(0x808080).r,
      closeTo(math.pow((128 / 255 + .055) / 1.055, 2.4), 1e-12),
    );
  });
}
