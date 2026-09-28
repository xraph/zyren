import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';

void main() {
  test(
    'triangle sidedness survives copies and defaults to existing visibility',
    () {
      expect(UnlitMaterial().side, MaterialSide.doubleSided);
      final front = UnlitMaterial(side: MaterialSide.front);
      expect(front.copyWith(opacity: .5).side, MaterialSide.front);
      expect(front.copyWith(side: MaterialSide.back).side, MaterialSide.back);
      final back = DiffuseMaterial(side: MaterialSide.back);
      expect(back.copyWith(opacity: .5).side, MaterialSide.back);
      expect(back.copyWith(side: MaterialSide.front).side, MaterialSide.front);
      expect(LineMaterial().side, MaterialSide.doubleSided);
      expect(PointsMaterial().side, MaterialSide.doubleSided);
    },
  );
  test(
    'sidedness changes are captured without reuploading shared geometry',
    () {
      final mesh = Mesh(PlaneGeometry(), UnlitMaterial());
      final scene = Scene()..add(mesh);
      final camera = PerspectiveCamera();
      FrameSubmission capture() => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(31, 31),
      );
      final before = capture();
      final encoder = ScenePacketEncoder(viewId: 1);
      encoder.accept(encoder.encode(before));
      mesh.material = UnlitMaterial(side: MaterialSide.front);
      final update = encoder.encode(capture());
      expect(update.changedMeshes, 1);
      expect(update.uploadedBytes, 0);
      expect(
        ByteData.sublistView(update.bytes).getUint32(4, Endian.little),
        17,
      );
      encoder.accept(update);
      expect(encoder.encode(capture()).changedMeshes, 0);
      final restore = encoder.encode(before);
      expect(restore.changedMeshes, 1);
      expect(restore.uploadedBytes, 0);
      expect((scene.snapshot(camera, 1)['meshes'] as List).single['side'], 1);
    },
  );
}
