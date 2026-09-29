import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';

void main() {
  test(
    'instance packets own versions and bound uploads independently of draws',
    () {
      final geometry = BoxGeometry();
      final mesh = InstancedMesh(geometry, UnlitMaterial(), count: 10000);
      final scene = Scene()..add(mesh);
      final camera = PerspectiveCamera();
      FrameSubmission capture() => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(31, 31),
      );
      final a = ScenePacketEncoder(viewId: 1),
          b = ScenePacketEncoder(viewId: 2);
      final frozen = capture();
      final initial = a.encode(frozen);
      expect(
        ByteData.sublistView(initial.bytes).getUint32(4, Endian.little),
        26,
      );
      expect(initial.uploadedBytes, geometry.capture().gpuByteLength + 1280000);
      expect(frozen.scene.drawCalls, 1);
      expect(frozen.scene.triangles, 120000);
      expect(() => frozen.toNativePacket(), throwsUnsupportedError);
      a.accept(initial);
      expect(b.encode(frozen).uploadedBytes, initial.uploadedBytes);
      mesh.setTransform(
        9999,
        Mat4.compose(const Vec3(1, 0, 0), Quat.identity, Vec3.one),
      );
      final changed = a.encode(capture());
      expect(changed.uploadedBytes, 128);
      a.accept(changed);
      mesh.count = 30;
      mesh.position = const Vec3(2, 0, 0);
      camera.position = const Vec3(0, 0, 6);
      final parent = a.encode(capture());
      expect(parent.uploadedBytes, 0);
      expect(parent.changedMeshes, 1);
      a.accept(parent);
      mesh.visible = false;
      mesh.setTransform(
        1,
        Mat4.compose(const Vec3(1, 0, 0), Quat.identity, Vec3.one),
      );
      final hidden = a.encode(capture());
      expect(hidden.uploadedBytes, 0);
      a.accept(hidden);
      mesh.visible = true;
      final shown = a.encode(capture());
      expect(shown.uploadedBytes, 128);
      a.accept(shown);
      final backtrack = a.encode(frozen);
      expect(backtrack.uploadedBytes, 1280000);
      a.accept(backtrack);
      expect(a.encode(frozen).uploadedBytes, 0);
      mesh.material = UnlitMaterial(
        alphaMode: MaterialAlphaMode.blend,
        opacity: .5,
      );
      expect(capture().scene.drawCalls, 30);
      mesh.count = 0;
      expect(capture().scene.drawCalls, 0);
    },
  );
  test(
    'view capacities include hidden instances and reject aggregate overflow',
    () {
      final geometry = BoxGeometry();
      final scene = Scene()
        ..add(
          InstancedMesh(geometry, UnlitMaterial(), count: 60000)
            ..visible = false,
        )
        ..add(InstancedMesh(geometry, UnlitMaterial(), count: 50000));
      expect(
        () => FrameSubmission.capture(
          scene: scene,
          camera: PerspectiveCamera(),
          size: PhysicalSize(1, 1),
        ),
        throwsArgumentError,
      );
    },
  );
}
