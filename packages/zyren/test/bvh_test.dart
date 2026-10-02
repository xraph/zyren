import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

BufferGeometry grid(int divisions, {bool dynamic = false, bool morph = false}) {
  final positions = <double>[], normals = <double>[], indices = <int>[];
  for (var y = 0; y <= divisions; y++) {
    for (var x = 0; x <= divisions; x++) {
      positions.addAll([x - divisions / 2, y - divisions / 2, 0]);
      normals.addAll([0, 0, 1]);
    }
  }
  for (var y = 0; y < divisions; y++) {
    for (var x = 0; x < divisions; x++) {
      final a = y * (divisions + 1) + x, b = a + 1, c = a + divisions + 1;
      indices.addAll([a, b, c + 1, a, c + 1, c]);
    }
  }
  return BufferGeometry(
    positions: positions,
    normals: normals,
    indices: indices,
    dynamic: dynamic,
    morphTargets: morph
        ? [
            MorphTarget(
              positions: [
                for (var i = 0; i < positions.length; i += 3) ...[0, 0, 2],
              ],
            ),
          ]
        : [],
  );
}

void sameHits(List<PickResult> a, List<PickResult> b) {
  expect(a.length, b.length);
  for (var i = 0; i < a.length; i++) {
    expect(a[i].object, same(b[i].object));
    expect(a[i].instanceIndex, b[i].instanceIndex);
    expect(a[i].triangleIndex, b[i].triangleIndex);
    expect(a[i].point.distanceTo(b[i].point), lessThan(1e-9));
    expect(a[i].distance, closeTo(b[i].distance, 1e-9));
    expect(a[i].uv, b[i].uv);
  }
}

void main() {
  test('BVH prunes dense triangle work and agrees with the linear oracle', () {
    final scene = Scene()..add(Mesh(grid(64), UnlitMaterial()));
    final accelerated = Raycaster(),
        linear = Raycaster(acceleration: RaycastAcceleration.none);
    final random = math.Random(412);
    for (var i = 0; i < 40; i++) {
      final ray = Ray(
        Vec3(random.nextDouble() * 80 - 40, random.nextDouble() * 80 - 40, 5),
        const Vec3(.04, .07, -1),
      );
      final report = accelerated.capture(scene, ray).trace(firstHitOnly: false);
      sameHits(report.hits, linear.capture(scene, ray).intersectAll());
      expect(report.statistics.triangleTests, lessThanOrEqualTo(32));
    }
    final ray = Ray(const Vec3(.13, .21, 5), const Vec3(0, 0, -1));
    final report = accelerated.capture(scene, ray).trace();
    expect(report.statistics.geometryBuilds, 0);
    expect(report.statistics.sceneBuilds, 0);
    expect(linear.capture(scene, ray).trace().statistics.triangleTests, 8192);
    expect(() => report.hits.clear(), throwsUnsupportedError);
  });
  test(
    'position refits leave frozen queries intact; other attributes reuse bounds',
    () {
      final source = grid(16, dynamic: true);
      final scene = Scene()..add(Mesh(source, UnlitMaterial()));
      final caster = Raycaster();
      final ray = Ray(const Vec3(.13, .21, 5), const Vec3(0, 0, -1));
      final old = caster.capture(scene, ray);
      expect(old.trace().statistics.geometryBuilds, 1);
      source.updateAttribute(
        VertexSemantic.normal,
        Float32List.fromList([1, 0, 0]),
      );
      final normalOnly = caster.capture(scene, ray).trace();
      expect(normalOnly.statistics.geometryBuilds, 0);
      expect(normalOnly.statistics.geometryRefits, 0);
      source.updateAttribute(
        VertexSemantic.position,
        Float32List.fromList([
          for (var i = 0; i < source.positions.length; i += 3) ...[
            source.positions[i],
            source.positions[i + 1],
            2,
          ],
        ]),
      );
      final moved = caster.capture(scene, ray).trace();
      expect(moved.statistics.geometryBuilds, 0);
      expect(moved.statistics.geometryRefits, 1);
      expect(moved.hits.single.point.z, 2);
      expect(old.intersectFirst()!.point.z, 0);
      caster.clearCache();
      expect(caster.capture(scene, ray).trace().statistics.geometryBuilds, 1);
      expect(old.intersectFirst()!.point.z, 0);
    },
  );
  test(
    'deformed trees refit per mesh without sharing poses or altering old requests',
    () {
      final source = grid(16, morph: true);
      final scene = Scene();
      final a = scene.add(Mesh(source, UnlitMaterial()));
      final b = scene.add(
        Mesh(source, UnlitMaterial())..position = const Vec3(0, 0, -1),
      );
      final caster = Raycaster(),
          linear = Raycaster(acceleration: RaycastAcceleration.none);
      final ray = Ray(const Vec3(.13, .21, 5), const Vec3(0, 0, -1));
      final old = caster.capture(scene, ray);
      a.setMorphWeight(0, 1);
      final changed = caster.capture(scene, ray).trace(firstHitOnly: false);
      expect(changed.statistics.geometryRefits, 1);
      expect(changed.hits.map((h) => h.point.z), [2, -1]);
      expect(changed.hits.last.object, same(b));
      sameHits(changed.hits, linear.capture(scene, ray).intersectAll());
      expect(old.intersectAll().map((h) => h.point.z), [0, -1]);
    },
  );
  test(
    'scene tree prunes 10000 instances and refreshes count, layers, transforms and removal',
    () {
      final scene = Scene();
      final mesh = scene.add(
        InstancedMesh(BoxGeometry(), UnlitMaterial(), count: 10000),
      );
      mesh.setTransforms(
        0,
        List.generate(
          10000,
          (i) => Mat4.compose(
            Vec3((i % 100) * 2.0, (i ~/ 100) * 2.0, 0),
            Quat.identity,
            const Vec3(-1, 2, .5),
          ),
        ),
      );
      final caster = Raycaster(),
          linear = Raycaster(acceleration: RaycastAcceleration.none);
      final ray = Ray(const Vec3(.13, .21, 5), const Vec3(0, 0, -1));
      final original = caster.capture(scene, ray);
      final report = original.trace(firstHitOnly: false);
      expect(report.statistics.meshTests, lessThan(20));
      sameHits(report.hits, linear.capture(scene, ray).intersectAll());
      mesh.setTransform(
        0,
        Mat4.compose(const Vec3(0, 0, 2), Quat.identity, Vec3.one),
      );
      final changed = caster.capture(scene, ray).trace();
      expect(changed.hits.single.point.z, 2.5);
      expect(changed.statistics.sceneBuilds, 0);
      expect(changed.statistics.sceneRefits, 1);
      expect(changed.statistics.modelMatrixInversions, 1);
      expect(original.intersectFirst()!.point.z, .25);
      mesh.count = 0;
      expect(caster.capture(scene, ray).intersectFirst(), isNull);
      mesh.count = 1;
      mesh.layers = LayerMask.none;
      expect(caster.capture(scene, ray).intersectFirst(), isNull);
      mesh.layers = LayerMask.only(0);
      scene.remove(mesh);
      expect(caster.capture(scene, ray).intersectFirst(), isNull);
    },
  );
  test(
    'equal-distance hits keep triangle and instance order through BVH traversal',
    () {
      final scene = Scene();
      final mesh = scene.add(
        InstancedMesh(grid(16), UnlitMaterial(), count: 12),
      );
      final ray = Ray(const Vec3(.5, .5, 5), const Vec3(0, 0, -1));
      final fast = Raycaster().capture(scene, ray);
      final slow = Raycaster(
        acceleration: RaycastAcceleration.none,
      ).capture(scene, ray);
      sameHits(fast.intersectAll(), slow.intersectAll());
      sameHits([fast.intersectFirst()!], [slow.intersectFirst()!]);
      expect(fast.intersectFirst()!.object, same(mesh));
      expect(fast.intersectFirst()!.instanceIndex, 0);
    },
  );
  test(
    'new topology builds a new tree without retaining the removed mesh in results',
    () {
      final scene = Scene(), caster = Raycaster();
      final oldMesh = scene.add(Mesh(grid(16), UnlitMaterial()));
      final ray = Ray(const Vec3(.13, .21, 5), const Vec3(0, 0, -1));
      final old = caster.capture(scene, ray);
      scene.remove(oldMesh);
      final next = scene.add(
        Mesh(grid(12), UnlitMaterial())..position = const Vec3(0, 0, 1),
      );
      final report = caster.capture(scene, ray).trace();
      expect(report.statistics.geometryBuilds, 1);
      expect(report.hits.single.object, same(next));
      expect(old.intersectFirst()!.object, same(oldMesh));
    },
  );
  test('joint edits refit bounds and normal edits preserve the posed tree', () {
    final base = grid(16);
    final source = BufferGeometry.fromAttributes(
      attributes: {
        ...base.attributes,
        VertexSemantic.joints: VertexAttribute(
          Uint16List(base.vertexCount * 4),
          format: VertexFormat.uint16x4,
        ),
        VertexSemantic.weights: VertexAttribute(
          Float32List.fromList([
            for (var i = 0; i < base.vertexCount; i++) ...[1, 0, 0, 0],
          ]),
          format: VertexFormat.float32x4,
        ),
      },
      indices: base.indices,
      dynamic: true,
    );
    final scene = Scene(), caster = Raycaster();
    final bone = scene.add(Bone());
    scene.add(
      SkinnedMesh(
        source,
        UnlitMaterial(),
        skin: Skin.fromBindPose(joints: [bone]),
      ),
    );
    final ray = Ray(const Vec3(.13, .21, 5), const Vec3(0, 0, -1));
    final initial = caster.capture(scene, ray);
    bone.position = const Vec3(0, 0, 2);
    final posed = caster.capture(scene, ray).trace();
    expect(posed.statistics.geometryRefits, 1);
    expect(posed.hits.single.point.z, 2);
    source.updateAttribute(
      VertexSemantic.normal,
      Float32List.fromList([1, 0, 0]),
    );
    final normal = caster.capture(scene, ray).trace();
    expect(normal.statistics.geometryRefits, 0);
    expect(normal.hits.single.point.z, 2);
    bone.position = const Vec3(30, 0, 0);
    expect(caster.capture(scene, ray).intersectFirst(), isNull);
    expect(initial.intersectFirst()!.point.z, 0);
  });
  test(
    'coincident partitions terminate and preserve all stable triangle ties',
    () {
      final source = BufferGeometry(
        positions: [-1, -1, 0, 1, -1, 0, 0, 1, 0],
        normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
        indices: [
          for (var i = 0; i < 4096; i++) ...[0, 1, 2],
        ],
      );
      final scene = Scene()..add(Mesh(source, UnlitMaterial()));
      final ray = Ray(const Vec3(.13, .21, 5), const Vec3(0, 0, -1));
      final fast = Raycaster().capture(scene, ray);
      final slow = Raycaster(
        acceleration: RaycastAcceleration.none,
      ).capture(scene, ray);
      sameHits(fast.intersectAll(), slow.intersectAll());
      expect(fast.intersectFirst()!.triangleIndex, 0);
    },
  );
  test(
    'front-first pruning keeps nearest hits under rotated nonuniform scales',
    () {
      final scene = Scene();
      final group = scene.add(Group()..scale = const Vec3(-2, 3, .5));
      final mesh = group.add(
        InstancedMesh(
          BoxGeometry(),
          UnlitMaterial(side: MaterialSide.doubleSided),
          count: 100,
        ),
      );
      mesh.setTransforms(
        0,
        List.generate(
          100,
          (i) => Mat4.compose(
            Vec3((i % 10) * 1.3, (i ~/ 10) * 1.3, i * .01),
            Quat.axisAngle(const Vec3(0, 1, 0), i * .1),
            Vec3(i.isEven ? -1 : 1, .75, 1.5),
          ),
        ),
      );
      final fast = Raycaster(),
          slow = Raycaster(acceleration: RaycastAcceleration.none);
      final random = math.Random(239);
      for (var i = 0; i < 100; i++) {
        final ray = Ray(
          Vec3(-random.nextDouble() * 26, random.nextDouble() * 40, 5),
          const Vec3(.04, -.07, -1),
        );
        final a = fast.capture(scene, ray), b = slow.capture(scene, ray);
        sameHits(a.intersectAll(), b.intersectAll());
        sameHits(a.trace().hits, b.trace().hits);
      }
    },
  );
}
