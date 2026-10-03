import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../layers/terrain_integration_test.dart'
    show LayerTestRenderer, layerCamera;

class Rig extends ScenePlugin implements GeoCameraRig {
  @override
  final String id;
  @override
  GeospatialCameraPose pose;
  bool active = false;
  GeospatialCameraPose Function(GeospatialCameraPose)? constraint;
  Rig(this.id, this.pose);
  @override
  void setActive(bool value) => active = value;
  @override
  GeospatialCameraPose constrain(GeospatialCameraPose value) =>
      constraint?.call(value) ?? value;
}

void main() {
  test(
    'modifiers declare components and constraints run before final publication',
    () {
      final controller = GeoCameraController(), camera = PerspectiveCamera();
      final rig = Rig('a', GeospatialCameraPose.fromCamera(camera));
      rig.constraint = (pose) => pose.copyWith(position: const Vec3(0, 0, 9));
      controller.registerRig('a', rig);
      final token = controller.registerModifier(
        'offset',
        0,
        (pose) => pose.copyWith(position: const Vec3(0, 0, 1)),
        components: {GeoCameraComponent.orientation},
      );
      expect(() => controller.publish('a', camera), throwsStateError);
      expect(camera.position.z, 5);
      token.dispose();
      controller.registerModifier(
        'offset',
        0,
        (pose) => pose.copyWith(position: const Vec3(0, 0, 1)),
        components: {GeoCameraComponent.position},
      );
      controller.publish('a', camera);
      expect(camera.position.z, 9);
    },
  );

  test(
    'one rig publishes a deterministic modifier chain without accumulating offsets',
    () {
      final controller = GeoCameraController();
      final camera = PerspectiveCamera();
      final first = Rig('a', GeospatialCameraPose.fromCamera(camera));
      final second = Rig(
        'b',
        first.pose.copyWith(position: const Vec3(0, 0, 20)),
      );
      final a = controller.registerRig(first.id, first),
          b = controller.registerRig(second.id, second);
      final plus = controller.registerModifier(
        'b',
        10,
        (p) => p.copyWith(position: p.position + const Vec3(0, 0, 1)),
      );
      final times = controller.registerModifier(
        'a',
        10,
        (p) => p.copyWith(position: p.position * 2),
      );
      expect(first.active, isTrue);
      expect(second.active, isFalse);
      controller.publish('a', camera);
      expect(camera.position.z, 11);
      controller.publish('a', camera);
      expect(camera.position.z, 11);
      controller.activate('b');
      expect(first.active, isFalse);
      expect(controller.publish('a', camera), isFalse);
      controller.publish('b', camera);
      expect(camera.position.z, 41);
      expect(() => controller.activate('missing'), throwsArgumentError);
      b.dispose();
      expect(controller.activeRigId, 'a');
      times.dispose();
      controller.publish('a', camera);
      expect(camera.position.z, 6);
      plus.dispose();
      a.dispose();
      expect(controller.activeRigId, isNull);
    },
  );
  test(
    'constraints run after modifiers and a failed modifier cannot publish a partial pose',
    () {
      final controller = GeoCameraController(), camera = PerspectiveCamera();
      controller.registerRig(
        'a',
        Rig('a', GeospatialCameraPose.fromCamera(camera)),
      );
      controller.registerModifier(
        'invalid',
        0,
        (p) => p.copyWith(up: Vec3.zero),
      );
      expect(() => controller.publish('a', camera), throwsArgumentError);
      expect(camera.up, const Vec3(0, 1, 0));
      expect(camera.position, const Vec3(0, 0, 5));
    },
  );
  test(
    'managed globe rigs switch independently and release scoped registrations',
    () async {
      final a = GlobeCameraExtension(id: 'a'),
          b = GlobeCameraExtension(id: 'b');
      final geo = GeospatialPlugin(extensions: [a, b]);
      final camera = layerCamera();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: camera,
        plugins: geo.scenePlugins,
        rendererFactory: () async => LayerTestRenderer(),
      );
      expect(geo.cameras.activeRigId, 'a');
      expect(a.camera.controls!.enabled, isTrue);
      expect(b.camera.controls!.enabled, isFalse);
      expect(a.camera.controls!.camera, isNot(same(camera)));
      geo.cameras.activate('b');
      await engine.render(
        elapsed: const Duration(milliseconds: 16),
        width: 64,
        height: 64,
      );
      expect(a.camera.controls!.enabled, isFalse);
      expect(b.camera.controls!.enabled, isTrue);
      await engine.dispose();
      expect(geo.cameras.rigIds, isEmpty);
      expect(a.camera.controls, isNull);
      expect(b.camera.controls, isNull);
    },
  );
}
