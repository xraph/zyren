import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';
import 'raycaster_test.dart' show triangle;
import 'mesh_shader_test.dart' show MeshDevice;

void main() {
  test('pose changes and aggregate instance bounds determine visibility', () {
    final scene = Scene();
    final bone = scene.add(Bone());
    final mesh = scene.add(
      SkinnedMesh(
        triangle(skin: true, morph: true),
        UnlitMaterial(),
        skin: Skin.fromBindPose(joints: [bone]),
      ),
    );
    final camera = OrthographicCamera(verticalSize: 4);
    int draws() => FrameSubmission.capture(
      scene: scene,
      camera: camera,
      size: PhysicalSize(100, 100),
    ).scene.drawCalls;
    expect(draws(), 1);
    mesh.setMorphWeight(0, 2);
    expect(draws(), 0);
    bone.position = const Vec3(-6, 0, 0);
    expect(draws(), 1);
    final instances = scene.add(
      InstancedMesh(BoxGeometry(), UnlitMaterial(), count: 16),
    );
    instances.setTransforms(
      0,
      List.generate(
        16,
        (i) => Mat4.compose(
          Vec3(20 + i * 2.0, 0, 0),
          Quat.identity,
          const Vec3(-2, 1, .5),
        ),
      ),
    );
    expect(draws(), 1);
    instances.setTransform(0, Mat4.identity());
    expect(draws(), 2);
    instances.count = 0;
    expect(draws(), 1);
  });
  test('unknown shader and expanded primitive bounds stay visible', () async {
    final compiler = ShaderCompiler(MeshDevice());
    try {
      final program = await compiler.compileMesh(ShaderSource.wgsl('valid'));
      final scene = Scene();
      final mesh = scene.add(
        Mesh(BoxGeometry(), ShaderMaterial(program))
          ..position = const Vec3(100, 0, 0),
      );
      final points = scene.add(
        Points(
          PointGeometry(points: [const Vec3(100, 0, 0)]),
          PointsMaterial(),
        ),
      );
      final camera = OrthographicCamera(verticalSize: 4);
      int draws() => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(100, 100),
      ).scene.drawCalls;
      expect(draws(), 2);
      mesh.cullingBounds = mesh.bounds;
      expect(draws(), 1);
      points.cullingBounds = points.bounds;
      expect(draws(), 0);
      mesh.frustumCulled = false;
      expect(draws(), 1);
    } finally {
      await compiler.close();
    }
  });
  test(
    'native clip volume includes six boundaries and rejects exterior boxes',
    () {
      final frustum = Frustum.fromMatrix(Mat4.identity());
      for (final point in [
        const Vec3(-1, 0, .5),
        const Vec3(1, 0, .5),
        const Vec3(0, -1, .5),
        const Vec3(0, 1, .5),
        Vec3.zero,
        const Vec3(0, 0, 1),
      ]) {
        expect(frustum.containsPoint(point), isTrue);
        expect(frustum.intersectsBounds(Bounds3(point, point)), isTrue);
      }
      for (final point in [
        const Vec3(-1.01, 0, .5),
        const Vec3(1.01, 0, .5),
        const Vec3(0, -1.01, .5),
        const Vec3(0, 1.01, .5),
        const Vec3(0, 0, -.01),
        const Vec3(0, 0, 1.01),
      ]) {
        expect(frustum.containsPoint(point), isFalse);
      }
      expect(frustum.intersectsBounds(null), isTrue);
      expect(frustum.intersectsBounds(const Bounds3.empty()), isFalse);
      expect(
        frustum.intersectsBounds(Bounds3(const Vec3(-2, -2, -2), Vec3.one)),
        isTrue,
      );
      expect(
        () => Frustum.fromMatrix(Mat4(List.filled(16, 0))),
        throwsArgumentError,
      );
    },
  );
  test(
    'camera frusta use native depth and retain precision far from the origin',
    () {
      const origin = Vec3(6378137, -6378137, 6378137);
      for (final camera in <Camera>[
        PerspectiveCamera(
          position: origin,
          target: origin + const Vec3(0, 0, -1),
          fieldOfView: math.pi / 2,
          near: 1,
          far: 10,
        ),
        OrthographicCamera(
          position: origin,
          target: origin + const Vec3(0, 0, -1),
          verticalSize: 4,
          near: 1,
          far: 10,
        ),
      ]) {
        final frustum = Frustum.fromCamera(camera, 1);
        expect(frustum.containsPoint(origin + const Vec3(0, 0, -1)), isTrue);
        expect(frustum.containsPoint(origin + const Vec3(0, 0, -10)), isTrue);
        expect(frustum.containsPoint(origin + const Vec3(0, 0, -.9)), isFalse);
        expect(
          frustum.containsPoint(origin + const Vec3(0, 0, -10.1)),
          isFalse,
        );
        expect(frustum.containsPoint(origin + const Vec3(0, 0, 2)), isFalse);
        expect(frustum.containsPoint(origin + const Vec3(30, 0, -2)), isFalse);
      }
    },
  );
  test('render capture culls color draws independently for each camera', () {
    final scene = Scene();
    final offscreen = scene.add(
      Mesh(BoxGeometry(), UnlitMaterial())..position = const Vec3(20, 0, 0),
    );
    scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    final camera = OrthographicCamera(verticalSize: 4);
    FrameSubmission capture(Camera view) => FrameSubmission.capture(
      scene: scene,
      camera: view,
      size: PhysicalSize(100, 100),
    );
    final first = capture(camera);
    expect(first.scene.drawCalls, 1);
    expect(first.scene.triangles, 12);
    final other = OrthographicCamera(
      position: const Vec3(20, 0, 5),
      target: const Vec3(20, 0, 0),
      verticalSize: 4,
    );
    expect(capture(other).scene.drawCalls, 1);
    offscreen.frustumCulled = false;
    expect(capture(camera).scene.drawCalls, 2);
    expect(first.scene.drawCalls, 1);
  });
  test(
    'culling bounds overrides change demand and can be reset to automatic',
    () {
      final scene = Scene();
      final mesh = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      final camera = OrthographicCamera(verticalSize: 4);
      int draws() => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(100, 100),
      ).scene.drawCalls;
      final revision = scene.revision;
      mesh.cullingBounds = Bounds3(const Vec3(20, 0, 0), const Vec3(21, 1, 1));
      expect(scene.revision, greaterThan(revision));
      expect(draws(), 0);
      mesh.cullingBounds = null;
      expect(draws(), 1);
    },
  );
}
