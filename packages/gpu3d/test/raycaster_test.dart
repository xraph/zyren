import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';

BufferGeometry triangle({
  bool dynamic = false,
  bool skin = false,
  bool morph = false,
}) => BufferGeometry.fromAttributes(
  attributes: {
    VertexSemantic.position: VertexAttribute(
      Float32List.fromList([-1, -1, 0, 1, -1, 0, 0, 1, 0]),
      format: VertexFormat.float32x3,
    ),
    VertexSemantic.normal: VertexAttribute(
      Float32List.fromList([0, 0, 1, 0, 0, 1, 0, 0, 1]),
      format: VertexFormat.float32x3,
    ),
    VertexSemantic.uv0: VertexAttribute(
      Float32List.fromList([0, 0, 1, 0, .5, 1]),
      format: VertexFormat.float32x2,
    ),
    if (skin)
      VertexSemantic.joints: VertexAttribute(
        Uint16List(12),
        format: VertexFormat.uint16x4,
      ),
    if (skin)
      VertexSemantic.weights: VertexAttribute(
        Float32List.fromList([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]),
        format: VertexFormat.float32x4,
      ),
  },
  indices: [0, 1, 2],
  dynamic: dynamic,
  morphTargets: morph
      ? [
          MorphTarget(positions: [3, 0, 0, 3, 0, 0, 3, 0, 0]),
        ]
      : [],
);

void main() {
  final ray = Ray(const Vec3(0, 0, 5), const Vec3(0, 0, -1));
  test('camera clipping includes near and far planes for oblique rays', () {
    for (final Camera camera in [
      PerspectiveCamera(
        position: Vec3.zero,
        target: const Vec3(0, 0, -1),
        near: 1,
        far: 6,
      ),
      OrthographicCamera(
        position: Vec3.zero,
        target: const Vec3(0, 0, -1),
        near: 1,
        far: 6,
      ),
    ]) {
      final scene = Scene();
      final mesh = scene.add(
        Mesh(triangle(), UnlitMaterial())..scale = const Vec3(10, 10, 1),
      );
      for (final depth in [1.0, 6.0]) {
        mesh.position = Vec3(0, 0, -depth);
        final hit = Raycaster()
            .captureFromCamera(
              scene,
              camera,
              const ViewportPoint(75, 50),
              logicalWidth: 100,
              logicalHeight: 100,
            )
            .intersectFirst();
        expect(hit, isNotNull, reason: '${camera.runtimeType} plane $depth');
        expect(hit!.point.z, closeTo(-depth, 1e-12));
      }
    }
  });
  test(
    'sorts by world distance after parent and nonuniform instance transforms',
    () {
      final scene = Scene();
      final parent = scene.add(Group()..scale = const Vec3(-2, 3, .5));
      final mesh = parent.add(
        InstancedMesh(
          triangle(),
          UnlitMaterial(side: MaterialSide.front),
          count: 2,
        ),
      );
      mesh.setTransform(
        1,
        Mat4.compose(const Vec3(0, 0, 4), Quat.identity, const Vec3(-.5, 1, 2)),
      );
      final hits = Raycaster().capture(scene, ray).intersectAll();
      expect(hits.map((h) => h.instanceIndex), [1, 0]);
      expect(hits.map((h) => h.distance), [3, 5]);
      expect(hits.first.object, same(mesh));
      expect(hits.first.point, const Vec3(0, 0, 2));
      expect(hits.first.triangle, [
        const Vec3(-1, -3, 2),
        const Vec3(1, -3, 2),
        const Vec3(0, 3, 2),
      ]);
      expect(() => hits.first.triangle[0] = Vec3.zero, throwsUnsupportedError);
      expect(hits.first.triangleIndex, 0);
      expect(hits.first.uv, (u: .5, v: .5));
      expect(hits.first.sceneRevision, scene.revision);
      expect(
        Raycaster(
          near: 4,
          far: 6,
        ).capture(scene, ray).intersectFirst()!.instanceIndex,
        0,
      );
      mesh.count = 0;
      expect(Raycaster().capture(scene, ray).intersectFirst(), isNull);
    },
  );
  test(
    'snapshots freeze transforms, geometry, material and active instance count',
    () {
      final scene = Scene();
      final geometry = triangle(dynamic: true);
      final mesh = scene.add(
        InstancedMesh(
          geometry,
          UnlitMaterial(side: MaterialSide.front),
          count: 2,
        ),
      );
      final snapshot = Raycaster().capture(scene, ray);
      final revision = scene.revision;
      mesh.count = 0;
      mesh.visible = false;
      mesh.material = UnlitMaterial(side: MaterialSide.back);
      mesh.position = const Vec3(50, 0, 0);
      geometry.updateAttribute(
        VertexSemantic.position,
        Float32List.fromList([10, 10, 0, 11, 10, 0, 10, 11, 0]),
      );
      expect(snapshot.intersectAll(), hasLength(2));
      expect(snapshot.intersectFirst()!.sceneRevision, revision);
      expect(snapshot.intersectFirst()!.point, Vec3.zero);
    },
  );
  test('picks captured morph and skin surfaces rather than the bind pose', () {
    final scene = Scene();
    final bone = scene.add(Bone());
    final mesh = scene.add(
      SkinnedMesh(
        triangle(skin: true, morph: true),
        UnlitMaterial(),
        skin: Skin.fromBindPose(joints: [bone]),
      ),
    );
    mesh.setMorphWeight(0, 1);
    bone.position = const Vec3(-3, 0, 2);
    final snapshot = Raycaster().capture(scene, ray);
    mesh.setMorphWeight(0, 0);
    bone.position = const Vec3(8, 0, 0);
    expect(snapshot.intersectFirst()!.point, const Vec3(0, 0, 2));
    expect(Raycaster().capture(scene, ray).intersectFirst(), isNull);
  });
  test(
    'visibility is inherited; layers filter each object independently in draws and picks',
    () {
      final scene = Scene();
      final group = scene.add(Group()..layers = LayerMask.none);
      final mesh = group.add(
        Mesh(triangle(), UnlitMaterial())..layers = LayerMask.only(2),
      );
      final camera = PerspectiveCamera();
      RaycastSnapshot pick() => Raycaster().captureFromCamera(
        scene,
        camera,
        const ViewportPoint(50, 50),
        logicalWidth: 100,
        logicalHeight: 100,
      );
      int draws() => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(100, 100),
      ).scene.drawCalls;
      expect(pick().intersectFirst(), isNull);
      expect(draws(), 0);
      camera.layers = LayerMask.only(2);
      expect(pick().intersectFirst()!.object, same(mesh));
      expect(draws(), 1);
      group.visible = false;
      expect(pick().intersectFirst(), isNull);
      expect(draws(), 0);
      expect(() => LayerMask.only(32), throwsRangeError);
      expect(LayerMask.only(31).including(0).excluding(31), LayerMask.only(0));
    },
  );
  test(
    'camera picks use native depth clipping and freeze camera plus revision',
    () {
      final scene = Scene();
      scene.add(Mesh(triangle(), UnlitMaterial()));
      final camera = PerspectiveCamera(near: 1, far: 6);
      RaycastSnapshot capture() => Raycaster().captureFromCamera(
        scene,
        camera,
        const ViewportPoint(50, 50),
        logicalWidth: 100,
        logicalHeight: 100,
      );
      final snapshot = capture();
      camera.position = const Vec3(20, 0, 5);
      expect(snapshot.intersectFirst()!.distance, closeTo(5, 1e-10));
      camera.position = const Vec3(0, 0, .5);
      expect(capture().intersectFirst(), isNull);
      camera.position = const Vec3(0, 0, 7);
      expect(capture().intersectFirst(), isNull);
    },
  );
  test(
    'orthographic rays stay parallel, preserve offset and clip both planes',
    () {
      final scene = Scene();
      final mesh = scene.add(
        Mesh(triangle(), UnlitMaterial())..position = const Vec3(1, 0, 0),
      );
      final camera = OrthographicCamera(verticalSize: 4, near: 1, far: 10);
      final pick = Raycaster().captureFromCamera(
        scene,
        camera,
        const ViewportPoint(75, 50),
        logicalWidth: 100,
        logicalHeight: 100,
      );
      expect(pick.ray.direction, const Vec3(0, 0, -1));
      expect(pick.ray.origin, const Vec3(1, 0, 5));
      expect(pick.intersectFirst()!.object, same(mesh));
      expect(pick.intersectFirst()!.point, const Vec3(1, 0, 0));
      camera.zoom = 2;
      final zoomed = Raycaster().captureFromCamera(
        scene,
        camera,
        const ViewportPoint(75, 50),
        logicalWidth: 100,
        logicalHeight: 100,
      );
      expect(zoomed.ray.origin.x, .5);
      expect(() => camera.verticalSize = 0, throwsArgumentError);
      expect(() => OrthographicCamera(near: 3, far: 1), throwsArgumentError);
    },
  );
  test(
    'invalid viewport, camera and singular world transforms have typed failures',
    () {
      final scene = Scene();
      final camera = PerspectiveCamera();
      final invalid = throwsA(
        isA<SceneException>().having(
          (e) => e.issue.code,
          'code',
          SceneIssueCodes.invalidPickRequest,
        ),
      );
      expect(
        () => Raycaster().captureFromCamera(
          scene,
          camera,
          const ViewportPoint(0, 0),
          logicalWidth: 0,
          logicalHeight: 100,
        ),
        invalid,
      );
      expect(
        () => Raycaster().captureFromCamera(
          scene,
          camera,
          const ViewportPoint(double.nan, 0),
          logicalWidth: 100,
          logicalHeight: 100,
        ),
        invalid,
      );
      camera.target = camera.position;
      expect(
        () => Raycaster().captureFromCamera(
          scene,
          camera,
          const ViewportPoint(50, 50),
          logicalWidth: 100,
          logicalHeight: 100,
        ),
        invalid,
      );
      final parent = scene.add(
        Group()..scale = const Vec3(1e-200, 1e-200, 1e-200),
      );
      parent.add(
        Mesh(triangle(), UnlitMaterial())
          ..scale = const Vec3(1e-200, 1e-200, 1e-200),
      );
      expect(() => Raycaster().capture(scene, ray), invalid);
    },
  );
}
