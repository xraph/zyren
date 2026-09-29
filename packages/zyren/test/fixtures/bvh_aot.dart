import 'dart:typed_data';
import 'package:zyren/zyren.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  final scene = Scene();
  final mesh = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
  final caster = Raycaster();
  final ray = Ray(const Vec3(.1, .2, 5), const Vec3(0, 0, -1));
  final old = caster.capture(scene, ray);
  check(old.intersectFirst()!.point.z == .5, 'Cold capture');
  final warm = caster.capture(scene, ray).trace();
  check(warm.statistics.modelMatrixInversions == 0, 'Warm capture');
  mesh.position = const Vec3(0, 0, 1);
  final moved = caster.capture(scene, ray).trace();
  check(moved.hits.single.point.z == 1.5, 'Moved capture');
  check(moved.statistics.sceneRefits == 1, 'Scene refit');
  check(old.intersectFirst()!.point.z == .5, 'Frozen capture');

  final instances = scene.add(
    InstancedMesh(BoxGeometry(), UnlitMaterial(), count: 24),
  );
  instances.setTransforms(
    0,
    List.generate(
      24,
      (i) => Mat4.compose(Vec3(i * 2.0, 0, 2), Quat.identity, Vec3.one),
    ),
  );
  final instanced = caster.capture(scene, ray);
  check(instanced.intersectFirst()!.instanceIndex == 0, 'Instance capture');
  instances.setTransform(
    0,
    Mat4.compose(const Vec3(0, 0, 3), Quat.identity, Vec3.one),
  );
  final changed = caster.capture(scene, ray).trace();
  check(changed.hits.single.point.z == 3.5, 'Instance edit');
  check(changed.statistics.modelMatrixInversions == 1, 'Reuse other instances');
  check(instanced.intersectFirst()!.point.z == 2.5, 'Frozen instances');

  final geometry = BufferGeometry(
    positions: [-1, -1, 0, 1, -1, 0, 0, 1, 0],
    normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
    indices: [0, 1, 2],
    dynamic: true,
    morphTargets: [
      MorphTarget(positions: [0, 0, 1, 0, 0, 1, 0, 0, 1]),
    ],
  );
  final deformed = Scene()..add(Mesh(geometry, UnlitMaterial()));
  final initial = caster.capture(deformed, ray);
  final surface = deformed.children.single as Mesh;
  surface.setMorphWeight(0, 1);
  final pose = caster.capture(deformed, ray).trace();
  check(pose.hits.single.point.z == 1, 'Morph position');
  check(pose.statistics.geometryRefits == 1, 'Morph refit');
  geometry.updateAttribute(
    VertexSemantic.position,
    Float32List.fromList([-1, -1, 1, 1, -1, 1, 0, 1, 1]),
  );
  final edited = caster.capture(deformed, ray).trace();
  check(edited.hits.single.point.z == 2, 'Geometry refit');
  check(initial.intersectFirst()!.point.z == 0, 'Frozen geometry');
  caster.clearCache();
  check(
    caster.capture(deformed, ray).trace().statistics.geometryBuilds == 1,
    'Cache reset',
  );
  check(initial.intersectFirst()!.point.z == 0, 'Retained query after reset');
  check(caster.capture(Scene(), ray).intersectFirst() == null, 'Empty scene');
  print('AOT picking passed.');
}
