import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'support/fakes.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

void main() {
  vm.Vector3 project(ShadowView view, Vec3 world, Camera camera) {
    final p = world - camera.position;
    final clip = vm.Matrix4.fromList(
      view.viewProjection,
    ).transformed(vm.Vector4(p.x, p.y, p.z, 1));
    return vm.Vector3(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w);
  }

  test(
    'cascades include off-camera casters and stabilize world positions below a texel',
    () {
      final scene = Scene();
      scene.add(
        Mesh(BoxGeometry(), StandardMaterial())
          ..castShadow = true
          ..position = const Vec3(0, 0, 10),
      );
      scene.add(
        DirectionalLight(shadow: DirectionalShadow(cascades: 1, distance: 30)),
      );
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 5), far: 100);
      ShadowView capture() => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(64, 64),
      ).shadows.views.single;
      final view = capture();
      final caster = project(view, const Vec3(0, 0, 10), camera);
      expect(caster.z, inInclusiveRange(0, 1));
      final a = project(view, Vec3.zero, camera);
      camera.position += const Vec3(.00001, 0, 0);
      camera.target += const Vec3(.00001, 0, 0);
      final b = project(capture(), Vec3.zero, camera);
      expect(b.x, closeTo(a.x, 1e-10));
      expect(b.y, closeTo(a.y, 1e-10));
    },
  );

  test(
    'point faces project their corresponding axes and spot projection honors clipping',
    () {
      final scene = Scene()
        ..add(PointLight(shadow: PointShadow(near: 1, far: 20)));
      scene.add(SpotLight(shadow: SpotShadow(near: 1, far: 20)));
      final camera = PerspectiveCamera();
      final views = FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(64, 64),
      ).shadows.views;
      final axes = [
        const Vec3(1, 0, 0),
        const Vec3(-1, 0, 0),
        const Vec3(0, 1, 0),
        const Vec3(0, -1, 0),
        const Vec3(0, 0, 1),
        const Vec3(0, 0, -1),
      ];
      for (var i = 0; i < 6; i++) {
        final near = project(views[i], axes[i], camera);
        final far = project(views[i], axes[i] * 20, camera);
        expect(near.x, closeTo(0, 1e-12));
        expect(near.y, closeTo(0, 1e-12));
        expect(near.z, closeTo(0, 1e-12));
        expect(far.z, closeTo(1, 1e-12));
      }
      expect(
        project(views.last, const Vec3(0, 0, -1), camera).z,
        closeTo(0, 1e-12),
      );
      expect(
        project(views.last, const Vec3(0, 0, -20), camera).z,
        closeTo(1, 1e-12),
      );
    },
  );

  test('atlas admission fails before silently dropping requested cascades', () {
    final scene = Scene()
      ..add(
        DirectionalLight(
          shadow: DirectionalShadow(cascades: 4, resolution: 1024),
        ),
      )
      ..add(SpotLight(shadow: SpotShadow()));
    expect(
      () => FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(64, 64),
      ),
      throwsArgumentError,
    );
  });
  test(
    'shadow settings and caster changes are captured independently of geometry uploads',
    () {
      final scene = Scene();
      final mesh = scene.add(
        Mesh(BoxGeometry(), StandardMaterial())
          ..castShadow = true
          ..receiveShadow = true,
      );
      final light = scene.add(
        DirectionalLight(shadow: DirectionalShadow(cascades: 3, distance: 30)),
      );
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 5), far: 100);
      final first = FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(64, 64),
      );
      expect(first.shadows.views.length, 3);
      expect(
        first.shadows.views.map((view) => view.lightIndex),
        everyElement(0),
      );
      expect(first.shadows.views.last.far, closeTo(30, 1e-6));
      final encoder = ScenePacketEncoder(viewId: 1);
      final packet = encoder.encode(first);
      encoder.accept(packet);
      mesh.castShadow = false;
      light.shadow = null;
      final next = encoder.encode(
        FrameSubmission.capture(
          scene: scene,
          camera: camera,
          size: PhysicalSize(64, 64),
        ),
      );
      expect(next.uploadedBytes, 0);
      expect(next.changedMeshes, 1);
      expect(first.shadows.views.length, 3, reason: 'immutable frame snapshot');
    },
  );

  test(
    'point and spot shadows prepare complete face sets with bounded settings',
    () {
      final scene = Scene()
        ..add(PointLight(shadow: PointShadow()))
        ..add(SpotLight(shadow: SpotShadow()));
      final frame = FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(64, 64),
      );
      expect(frame.shadows.views.length, 7);
      expect(
        frame.shadows.views.take(6).map((v) => v.lightIndex),
        everyElement(0),
      );
      expect(frame.shadows.views.last.lightIndex, 1);
      for (final invalid in [0, 127, 129, 2048]) {
        expect(
          () => DirectionalShadow(resolution: invalid),
          throwsArgumentError,
        );
      }
      expect(() => DirectionalShadow(cascades: 5), throwsArgumentError);
      expect(() => SpotShadow(near: 2, far: 1), throwsArgumentError);
      expect(() => PointShadow(bias: double.nan), throwsArgumentError);
    },
  );

  test('geometry bounds belong to each immutable revision', () {
    final geometry = PlaneGeometry(dynamic: true);
    final before = geometry.capture();
    geometry.updateAttribute(
      VertexSemantic.position,
      Float32List.fromList([-20, -30, 40]),
    );
    final after = geometry.capture();
    expect(before.bounds.minimum, const Vec3(-.5, -.5, 0));
    expect(after.bounds.minimum, const Vec3(-20, -30, 0));
    expect(after.bounds.maximum.z, 40);
    expect(identical(after.bounds, geometry.capture().bounds), isTrue);
  });
  test('unsupported shadow materials and legacy packets fail explicitly', () {
    final mesh = Mesh(PlaneGeometry(), UnlitMaterial())..castShadow = true;
    final scene = Scene()..add(mesh);
    final camera = PerspectiveCamera();
    expect(() => scene.snapshot(camera, 1), throwsUnsupportedError);
    FrameSubmission capture() => FrameSubmission.capture(
      scene: scene,
      camera: camera,
      size: PhysicalSize(1, 1),
    );
    expect(() => capture().toNativePacket(), throwsUnsupportedError);
    mesh.material = UnlitMaterial(alphaMode: MaterialAlphaMode.blend);
    expect(capture, throwsUnsupportedError);
    mesh.material = UnlitMaterial();
    mesh.receiveShadow = true;
    expect(capture, throwsUnsupportedError);
  });
  test('unsupported adapters reject shadows before submission', () async {
    final renderer = TestRenderer([]);
    final mesh = Mesh(PlaneGeometry(), UnlitMaterial())..castShadow = true;
    final engine = await SceneEngine.create(
      scene: Scene()..add(mesh),
      camera: PerspectiveCamera(),
      rendererFactory: () async => renderer,
    );
    try {
      await expectLater(
        engine.renderFrame(elapsed: Duration.zero, width: 1, height: 1),
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.requiredFeatures,
            'missing feature',
            contains(RenderFeature.shadows),
          ),
        ),
      );
      expect(renderer.renders, 0);
      mesh.visible = false;
      await engine.renderFrame(elapsed: Duration.zero, width: 1, height: 1);
      expect(renderer.renders, 1);
    } finally {
      await engine.dispose();
    }
  });
}
