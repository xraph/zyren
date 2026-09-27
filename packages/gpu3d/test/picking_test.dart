import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';

void expectVector(Vec3 actual, Vec3 expected, [double tolerance = 1e-10]) {
  expect(actual.x, closeTo(expected.x, tolerance));
  expect(actual.y, closeTo(expected.y, tolerance));
  expect(actual.z, closeTo(expected.z, tolerance));
}

void main() {
  final picker = Raycaster();
  Mesh plane({String? name}) =>
      Mesh(PlaneGeometry(width: 2, height: 2), UnlitMaterial(), name: name);
  final downward = CameraRay(const Vec3(.25, .5, 5), const Vec3(0, 0, -1));
  final invalid = isA<SceneException>().having(
    (e) => e.issue.code,
    'code',
    SceneIssueCodes.invalidPickRequest,
  );

  test('triangle hit reports world distance, UVs and captured revision', () {
    final scene = Scene();
    final mesh = scene.add(plane(name: 'panel'));
    final hit = picker.intersectScene(scene, downward).single;
    expect(hit.object, same(mesh));
    expectVector(hit.point, const Vec3(.25, .5, 0));
    expectVector(hit.normal, const Vec3(0, 0, 1));
    expect(hit.distance, 5);
    expect(hit.triangleIndex, 1);
    expect(hit.instanceIndex, isNull);
    expect(hit.uv!.u, closeTo(.625, 1e-12));
    expect(hit.uv!.v, closeTo(.25, 1e-12));
    expect(hit.sceneRevision, scene.revision);
    mesh.position = const Vec3(0, 0, 3);
    expect(hit.sceneRevision, lessThan(scene.revision));
    expectVector(hit.point, const Vec3(.25, .5, 0));
    expect(picker.intersectScene(scene, downward).single.distance, 2);
  });

  test(
    'nearest ordering uses world distance under nested nonuniform scale',
    () {
      final scene = Scene();
      final far = scene.add(plane(name: 'far'));
      final group = scene.add(Group())
        ..position = const Vec3(0, 0, 2)
        ..scale = const Vec3(2, 3, .25);
      final near = group.add(plane(name: 'near'))
        ..position = const Vec3(0, 0, 4);
      final hits = picker.intersectScene(scene, downward);
      expect(hits.map((hit) => hit.object), [near, far]);
      expect(hits.map((hit) => hit.distance), [2, 5]);
      expectVector(hits.first.point, const Vec3(.25, .5, 3));
      expect(
        picker.intersectScene(scene, downward, near: 3).single.object,
        far,
      );
      expect(
        picker.intersectScene(scene, downward, far: 3).single.object,
        near,
      );
      expect(picker.intersectScene(scene, downward, near: 2, far: 2).length, 1);
    },
  );

  test('hidden ancestors exclude descendants and removal invalidates hits', () {
    final scene = Scene();
    final group = scene.add(Group());
    final mesh = group.add(plane());
    expect(picker.intersectScene(scene, downward), hasLength(1));
    group.visible = false;
    expect(picker.intersectScene(scene, downward), isEmpty);
    group.visible = true;
    mesh.visible = false;
    expect(picker.intersectScene(scene, downward), isEmpty);
    mesh.visible = true;
    group.remove(mesh);
    expect(picker.intersectScene(scene, downward), isEmpty);
    scene.add(mesh);
    scene.visible = false;
    expect(picker.intersectScene(scene, downward), isEmpty);
  });

  test('misses, parallel rays and triangles behind the ray return no hit', () {
    final scene = Scene()..add(plane());
    for (final ray in [
      CameraRay(const Vec3(2, .5, 5), const Vec3(0, 0, -1)),
      CameraRay(const Vec3(0, 0, 5), const Vec3(1, 0, 0)),
      CameraRay(const Vec3(0, 0, 5), const Vec3(0, 0, 1)),
    ]) {
      expect(picker.intersectScene(scene, ray), isEmpty);
    }
  });

  test('double-sided hits survive mirrored geometry and back-side rays', () {
    final scene = Scene();
    final mesh = scene.add(plane())..scale = const Vec3(-2, 3, 1);
    final front = picker.intersectScene(scene, downward).single;
    expect(front.object, same(mesh));
    expectVector(front.point, const Vec3(.25, .5, 0));
    expectVector(front.normal, const Vec3(0, 0, 1));
    expect(front.uv!.u, closeTo(.4375, 1e-12));
    final back = picker
        .intersectScene(
          scene,
          CameraRay(const Vec3(.25, .5, -5), const Vec3(0, 0, 1)),
        )
        .single;
    expect(back.distance, 5);
    expectVector(back.normal, front.normal);
  });

  test(
    'inverse-transpose normal handles nonuniform scale on a sloped face',
    () {
      final geometry = BufferGeometry(
        positions: [0, 0, 0, 2, 0, 0, 0, 2, 2],
        normals: [0, -1, 1, 0, -1, 1, 0, -1, 1],
        indices: [0, 1, 2],
      );
      final scene = Scene()
        ..add(Mesh(geometry, UnlitMaterial())..scale = const Vec3(1, 2, .5));
      final hit = picker
          .intersectScene(
            scene,
            CameraRay(const Vec3(.5, 1, 5), const Vec3(0, 0, -1)),
          )
          .single;
      expectVector(hit.point, const Vec3(.5, 1, .25));
      expectVector(hit.normal, Vec3(0, -1 / math.sqrt(17), 4 / math.sqrt(17)));
      expect(hit.uv, isNull);
    },
  );

  test('shared edges retain deterministic triangle order', () {
    final scene = Scene()..add(plane());
    final hits = picker.intersectScene(
      scene,
      CameraRay(const Vec3(0, 0, 5), const Vec3(0, 0, -1)),
    );
    expect(hits.map((hit) => hit.triangleIndex), [0, 1]);
    expect(hits.map((hit) => hit.distance), [5, 5]);
  });

  test('degenerate triangles do not prevent later valid hits', () {
    final scene = Scene()
      ..add(
        Mesh(
          BufferGeometry(
            positions: [-1, -1, 0, 1, -1, 0, 0, 1, 0],
            normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            indices: [0, 0, 0, 0, 1, 2],
          ),
          UnlitMaterial(),
        ),
      );
    expect(
      picker
          .intersectScene(
            scene,
            CameraRay(const Vec3(0, 0, 2), const Vec3(0, 0, -1)),
          )
          .single
          .triangleIndex,
      1,
    );
  });

  test(
    'UV1 interpolation is independent of UV0 and shared geometry owners',
    () {
      final geometry = BufferGeometry(
        positions: [0, 0, 0, 2, 0, 0, 0, 2, 0],
        normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
        indices: [0, 1, 2],
        uv0: [0, 0, 1, 0, 0, 1],
        uv1: [.25, .5, .75, .5, .25, 1],
      );
      final scene = Scene();
      final first = scene.add(Mesh(geometry, UnlitMaterial()));
      final second = scene.add(Mesh(geometry, UnlitMaterial()))
        ..position = const Vec3(0, 0, -2);
      final ray = CameraRay(const Vec3(.5, .5, 5), const Vec3(0, 0, -1));
      final hits = picker.intersectScene(scene, ray);
      expect(hits.map((hit) => hit.distance), [5, 7]);
      expectVector(hits.first.barycentric, const Vec3(.5, .25, .25));
      expect(hits.first.uv, (u: .25, v: .25));
      expect(hits.first.uv1, (u: .375, v: .625));
      scene.remove(first);
      expect(picker.intersectScene(scene, ray).single.object, same(second));
    },
  );

  test('Earth-scale translations preserve small local surface coordinates', () {
    final scene = Scene();
    final group = scene.add(Group())..position = const Vec3(6378137, 100, 3000);
    group.add(plane());
    final hit = picker
        .intersectScene(
          scene,
          CameraRay(const Vec3(6378137.25, 100.5, 3005), const Vec3(0, 0, -1)),
        )
        .single;
    expectVector(hit.point, const Vec3(6378137.25, 100.5, 3000));
    expect(hit.distance, 5);
  });

  test('bounds handle zero direction, boundary origins and interior rays', () {
    final box = Bounds3(const Vec3(-1, -1, -1), const Vec3(1, 1, 1));
    final entry = box.intersectRay(
      CameraRay(const Vec3(1, 0, 5), const Vec3(0, 0, -1)),
    );
    expect(entry, (near: 4.0, far: 6.0));
    expect(box.intersectRay(CameraRay(Vec3.zero, const Vec3(1, 0, 0))), (
      near: 0.0,
      far: 1.0,
    ));
    expect(
      box.intersectRay(CameraRay(const Vec3(2, 0, 5), const Vec3(0, 0, -1))),
      isNull,
    );
    expect(
      box.intersectRay(
        CameraRay(const Vec3(0, 0, 5), const Vec3(0, 0, -1)),
        far: 3,
      ),
      isNull,
    );
  });

  test(
    'invalid ranges and unrepresentable transforms return typed failures',
    () {
      final scene = Scene()..add(plane());
      for (final range in [
        (double.nan, 5.0),
        (-1.0, 5.0),
        (2.0, 1.0),
        (0.0, double.nan),
      ]) {
        expect(
          () => picker.intersectScene(
            scene,
            downward,
            near: range.$1,
            far: range.$2,
          ),
          throwsA(invalid),
        );
      }
      (scene.children.single as Mesh).scale = const Vec3(
        1e-200,
        1e-200,
        1e-200,
      );
      expect(() => picker.intersectScene(scene, downward), throwsA(invalid));
    },
  );
}
