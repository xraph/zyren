import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';

void main() {
  test('a failed nested batch publishes its final mutation once', () async {
    final scene = Scene();
    final mesh = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    await Future<void>.delayed(Duration.zero);
    final revisions = <int>[];
    final subscription = scene.changes.listen(revisions.add);
    final before = scene.revision;
    expect(
      () => scene.batch(() {
        mesh.position = const Vec3(4, 0, 0);
        scene.batch(() => mesh.visible = false);
        throw StateError('application callback failed');
      }),
      throwsStateError,
    );
    expect(mesh.position, const Vec3(4, 0, 0));
    expect(scene.revision, greaterThan(before));
    await Future<void>.delayed(Duration.zero);
    expect(revisions, [scene.revision]);
    await subscription.cancel();
  });

  test('every visible edit wakes an idle scheduler', () async {
    final scene = Scene();
    final group = scene.add(Group());
    final mesh = group.add(Mesh(BoxGeometry(), UnlitMaterial()));
    final camera = PerspectiveCamera();
    final scheduler = FrameScheduler();
    final subscriptions = [
      scene.changes.listen((_) => scheduler.request()),
      camera.changes.listen((_) => scheduler.request()),
    ];
    var clock = Duration.zero;
    for (final edit in <void Function()>[
      () => mesh.position = const Vec3(1, 2, 3),
      () => mesh.material = UnlitMaterial(color: const Color3(1, 0, 0)),
      () => mesh.visible = false,
      () => group.rotateY(Angle.degrees(90)),
      () => camera.position = const Vec3(2, 3, 5),
      () => scene.background = const Color3(0, 0, 0),
    ]) {
      await Future<void>.delayed(Duration.zero);
      scheduler.tick(clock);
      clock += const Duration(seconds: 1);
      expect(scheduler.tick(clock), isNull);
      edit();
      await Future<void>.delayed(Duration.zero);
      expect(scheduler.tick(clock), isNotNull);
      clock += const Duration(seconds: 1);
    }
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  });

  test('reparenting notifies both scenes and rejects cycles', () {
    final a = Scene(), b = Scene();
    final group = a.add(Group());
    final mesh = group.add(Mesh(BoxGeometry(), DiffuseMaterial()));
    final beforeA = a.revision, beforeB = b.revision;
    b.add(group);
    expect(a.children, isEmpty);
    expect(group.parent, same(b));
    expect(a.revision, greaterThan(beforeA));
    expect(b.revision, greaterThan(beforeB));
    expect(() => mesh.add(b), throwsArgumentError);
    final oldA = a.revision, oldB = b.revision;
    mesh.translate(const Vec3(1, 0, 0));
    expect(a.revision, oldA);
    expect(b.revision, greaterThan(oldB));
  });

  test('two scenes share immutable geometry without sharing transforms', () {
    final geometry = BoxGeometry();
    final a = Scene(), b = Scene();
    final first = a.add(Mesh(geometry, UnlitMaterial()));
    final second = b.add(Mesh(geometry, UnlitMaterial()));
    first.position = const Vec3(7, 0, 0);
    a.remove(first);
    expect(second.geometry.id, geometry.id);
    expect(second.position, Vec3.zero);
    expect(b.snapshot(PerspectiveCamera(), 1)['meshes'], hasLength(1));
  });

  test('math values preserve precision and cannot mutate scene storage', () {
    final object = Object3D()..position = const Vec3(6378137.001, 0, 0);
    final vector = object.position.toVectorMath()..x = 0;
    expect(vector.x, 0);
    expect(object.position.x, 6378137.001);
    final matrix = object.localMatrix;
    expect(() => matrix.storage[12] = 0, throwsUnsupportedError);
    matrix.toVectorMath().setEntry(0, 3, 0);
    expect(matrix.storage[12], 6378137.001);
    object.rotateZ(Angle.degrees(90));
    final rotated = object.quaternion.rotate(const Vec3(1, 0, 0));
    expect(rotated.x, closeTo(0, 1e-12));
    expect(rotated.y, closeTo(1, 1e-12));
    expect(Angle.degrees(180), math.pi);
  });

  test('invalid transforms fail before revision changes', () {
    final object = Object3D();
    final before = object.revision;
    expect(
      () => object.position = const Vec3(double.nan, 0, 0),
      throwsArgumentError,
    );
    expect(() => object.scale = const Vec3(1, 0, 1), throwsArgumentError);
    expect(
      () => object.quaternion = const Quat(0, 0, 0, 0),
      throwsArgumentError,
    );
    expect(() => object.rotateY(double.infinity), throwsArgumentError);
    expect(() => Mat4(List.filled(16, double.nan)), throwsArgumentError);
    expect(() => Mat4(List.filled(16, 0)).inverted(), throwsArgumentError);
    expect(object.revision, before);
  });

  test(
    'restoring normalized rotations preserves the exact pose and revision',
    () {
      for (final rotation in [
        Quat.axisAngle(const Vec3(1, 0, 0), .35),
        const Quat(.13, .37, .71, .23),
        const Quat(7, -2, 4, 8),
      ]) {
        final object = Object3D()..quaternion = rotation;
        final saved = object.quaternion;
        final revision = object.revision;
        expect(saved.toVectorMath().length2, closeTo(1, 1e-15));
        for (var i = 0; i < 30; i++) {
          object.quaternion = saved;
          expect(object.quaternion, saved);
          expect(object.revision, revision);
        }
      }
    },
  );
}
