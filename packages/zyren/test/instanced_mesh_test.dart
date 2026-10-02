import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';

Mat4 transform(double x, {double z = 0, bool mirror = false}) =>
    Mat4.compose(Vec3(x, 0, z), Quat.identity, Vec3(mirror ? -1 : 1, 2, 1));

void main() {
  test(
    'instance slots retain their identity through edits and camera-relative capture',
    () {
      final scene = Scene()..position = const Vec3(6378137, 0, 0);
      final mesh = scene.add(
        InstancedMesh(PlaneGeometry(), UnlitMaterial(), count: 2),
      );
      mesh.setTransform(0, transform(-2));
      mesh.setTransform(1, transform(2, mirror: true));
      final camera = PerspectiveCamera(
        position: const Vec3(6378137, 0, 5),
        target: const Vec3(6378137, 0, 0),
      );
      FrameSubmission capture() => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(32, 32),
      );
      final first = capture(), encoder = ScenePacketEncoder(viewId: 500);
      var packet = encoder.encode(first);
      expect(packet.bytes.buffer.asByteData().getUint32(4, Endian.little), 26);
      encoder.accept(packet);
      expect(first.scene.triangles, 4);
      expect(encoder.encode(capture()).changedMeshes, 0);
      final picker = Raycaster();
      final ray = CameraRay(const Vec3(6378139.1, .2, 5), const Vec3(0, 0, -1));
      final hit = picker.intersectScene(scene, ray).single;
      expect(hit.object, same(mesh));
      expect(hit.instanceIndex, 1);
      expect(hit.distance, closeTo(5, 1e-9));
      mesh.setTransform(1, transform(2, z: 1, mirror: true));
      expect(picker.intersectScene(scene, ray).single.instanceIndex, 1);
      expect(
        picker.intersectScene(scene, ray).single.distance,
        closeTo(4, 1e-9),
      );
      packet = encoder.encode(capture());
      expect(packet.changedMeshes, 1);
      expect(packet.uploadedBytes, 128);
      encoder.accept(packet);
      expect(encoder.encode(first).changedMeshes, 1);
      expect(hit.distance, 5);
    },
  );
  test(
    'instance bounds, invalid transforms and frame budgets fail before native work',
    () {
      final mesh = InstancedMesh(
        BoxGeometry(),
        StandardMaterial(),
        count: 10000,
      );
      for (var i = 0; i < mesh.count; i++) {
        mesh.setTransform(i, transform(i.toDouble()));
      }
      expect(mesh.transformAt(9999), transform(9999));
      expect(() => mesh.setTransform(10000, transform(0)), throwsRangeError);
      expect(
        () => mesh.setTransform(
          0,
          Mat4.compose(Vec3.zero, Quat.identity, Vec3.zero),
        ),
        throwsArgumentError,
      );
      final projective = Mat4.identity().storage.toList()..[3] = .1;
      expect(() => mesh.setTransform(0, Mat4(projective)), throwsArgumentError);
      expect(
        () => InstancedMesh(BoxGeometry(), StandardMaterial(), count: 100001),
        throwsRangeError,
      );
      final scene = Scene()..add(mesh);
      final frame = FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(8, 8),
      );
      final packet = ScenePacketEncoder(viewId: 1).encode(frame);
      expect(packet.uploadedBytes, greaterThanOrEqualTo(10000 * 128));
      expect(packet.bytes.length, lessThan(1400000));
      expect(frame.scene.triangles, 120000);
      final revision = scene.revision;
      mesh.quaternion = Quat.axisAngle(const Vec3(0, 1, 0), math.pi);
      expect(scene.revision, greaterThan(revision));
    },
  );
}
