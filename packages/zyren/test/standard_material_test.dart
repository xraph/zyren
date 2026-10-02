import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';
import 'support/fakes.dart';

FrameSubmission capture(Scene scene, [PerspectiveCamera? camera]) =>
    FrameSubmission.capture(
      scene: scene,
      camera: camera ?? PerspectiveCamera(),
      size: PhysicalSize(31, 31),
      time: const FrameTime(),
    );

void main() {
  test(
    'camera layers filter material and light requirements before rendering',
    () async {
      final renderer = TestRenderer([]);
      final scene = Scene();
      scene.add(
        Mesh(PlaneGeometry(), StandardMaterial())..layers = LayerMask.only(1),
      );
      scene.add(HemisphereLight()..layers = LayerMask.only(1));
      final camera = PerspectiveCamera();
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        rendererFactory: () async => renderer,
      );
      try {
        await engine.renderFrame(elapsed: Duration.zero, width: 31, height: 31);
        expect(renderer.renders, 1);
        camera.layers = LayerMask.only(1);
        await expectLater(
          engine.renderFrame(elapsed: Duration.zero, width: 31, height: 31),
          throwsA(isA<SceneException>()),
        );
        expect(renderer.renders, 1);
      } finally {
        await engine.dispose();
      }
    },
  );
  test('legacy snapshots reject lighting they cannot represent', () {
    final scene = Scene();
    final mesh = scene.add(Mesh(PlaneGeometry(), StandardMaterial()));
    final camera = PerspectiveCamera();
    expect(() => scene.snapshot(camera, 1), throwsUnsupportedError);
    mesh.visible = false;
    final light = scene.add(PointLight());
    expect(() => scene.snapshot(camera, 1), throwsUnsupportedError);
    light.visible = false;
    expect(scene.snapshot(camera, 1)['meshes'], isEmpty);
  });
  test('standard edits advance mesh deltas without uploading geometry', () {
    final material = StandardMaterial();
    final mesh = Mesh(PlaneGeometry(), material);
    final scene = Scene()..add(mesh);
    final encoder = ScenePacketEncoder(viewId: 1);
    encoder.accept(encoder.encode(capture(scene)));
    mesh.material = material.copyWith(roughness: .25);
    final next = encoder.encode(capture(scene));
    expect(next.changedMeshes, 1);
    expect(next.uploadedBytes, 0);
    encoder.accept(next);
    expect(encoder.encode(capture(scene)).changedMeshes, 0);
  });
  test('distant light origins do not cancel their direction', () {
    final scene = Scene()
      ..add(DirectionalLight()..position = const Vec3(0, 0, 1e20));
    expect(
      ((capture(scene).toNativePacket()['lights'] as List).single
          as Map)['direction'],
      [0, 0, -1],
    );
  });

  test(
    'unsupported adapters reject standard materials before rendering',
    () async {
      final renderer = TestRenderer([]);
      final mesh = Mesh(PlaneGeometry(), StandardMaterial());
      final engine = await SceneEngine.create(
        scene: Scene()..add(mesh),
        camera: PerspectiveCamera(),
        rendererFactory: () async => renderer,
      );
      try {
        await expectLater(
          engine.renderFrame(elapsed: Duration.zero, width: 31, height: 31),
          throwsA(isA<SceneException>()),
        );
        expect(renderer.renders, 0);
        mesh.visible = false;
        final hemisphere = engine.scene.add(HemisphereLight());
        await expectLater(
          engine.renderFrame(elapsed: Duration.zero, width: 31, height: 31),
          throwsA(isA<SceneException>()),
        );
        expect(renderer.renders, 0);
        hemisphere.visible = false;
        await engine.renderFrame(elapsed: Duration.zero, width: 31, height: 31);
        expect(renderer.renders, 1);
      } finally {
        await engine.dispose();
      }
    },
  );

  test('standard parameters reject invalid energy and surface values', () {
    for (final invalid in [-.1, 1.1, double.nan, double.infinity]) {
      expect(() => StandardMaterial(metallic: invalid), throwsArgumentError);
      expect(() => StandardMaterial(roughness: invalid), throwsArgumentError);
    }
    expect(() => StandardMaterial(emissiveIntensity: -1), throwsArgumentError);
    final base = StandardMaterial(
      baseColor: const Color3(.3, .4, .5),
      metallic: .7,
      roughness: .4,
      emissive: const Color3(.1, .2, .3),
      emissiveIntensity: 2,
    );
    final mesh = Mesh(BoxGeometry(), base.copyWith(roughness: .8));
    final scene = Scene()..add(mesh);
    final packet = capture(scene).toNativePacket();
    final material = ((packet['meshes'] as List).single as Map)['pbr'] as Map;
    expect(material['metallic'], .7);
    expect(material['roughness'], .8);
    expect(material['emissive'], [.2, .4, .6]);
  });
  test(
    'lights inherit transforms, visibility and camera-relative position',
    () {
      final scene = Scene();
      final group = scene.add(Group()..position = const Vec3(10, 0, 0));
      final sun = group.add(DirectionalLight(intensity: 2));
      sun.rotateY(math.pi / 2);
      final point = group.add(
        PointLight(intensity: 4)..position = const Vec3(0, 0, 2),
      );
      final camera = PerspectiveCamera(position: const Vec3(10, 0, 5));
      final snapshot = capture(scene, camera);
      final lights = snapshot.toNativePacket()['lights'] as List;
      expect((lights[0] as Map)['direction'], [
        closeTo(-1, 1e-12),
        0.0,
        closeTo(0, 1e-12),
      ]);
      expect((lights[1] as Map)['position'], [0.0, 0.0, -3.0]);
      final revision = scene.revision;
      point.intensity = 8;
      expect(scene.revision, greaterThan(revision));
      expect((lights[1] as Map)['intensity'], 4);
      group.visible = false;
      expect(capture(scene, camera).toNativePacket()['lights'], isEmpty);
    },
  );
  test('punctual light validation and count limits fail before submission', () {
    expect(() => PointLight(range: -1), throwsArgumentError);
    expect(
      () => DirectionalLight(intensity: double.infinity),
      throwsArgumentError,
    );
    expect(
      () => SpotLight(innerConeAngle: 1, outerConeAngle: .5),
      throwsArgumentError,
    );
    final scene = Scene();
    for (var i = 0; i < 17; i++) {
      scene.add(PointLight());
    }
    expect(() => capture(scene), throwsArgumentError);
  });
}
