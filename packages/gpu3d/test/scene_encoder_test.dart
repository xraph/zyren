import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';

void main() {
  test('binary frames capture geometry and send only changed mesh records', () {
    final scene = Scene();
    final mesh = Mesh(BoxGeometry(), UnlitMaterial());
    scene.add(mesh);
    final encoder = ScenePacketEncoder(viewId: 1);
    FrameSubmission capture() => FrameSubmission.capture(
      scene: scene,
      camera: PerspectiveCamera(),
      size: PhysicalSize(31, 31),
    );
    final first = encoder.encode(capture());
    expect(first.uploadedBytes, 720);
    expect(ByteData.sublistView(first.bytes).getUint32(0, Endian.little), 2);
    encoder.accept(first);
    mesh.position = const Vec3(1, 0, 0);
    final changed = encoder.encode(capture());
    expect(changed.uploadedBytes, 0);
    expect(changed.changedMeshes, 1);
    expect(changed.bytes.length, lessThan(first.bytes.length));
    encoder.accept(changed);
    final same = encoder.encode(capture());
    expect(same.changedMeshes, 0);
    mesh.visible = false;
    final hidden = encoder.encode(capture());
    encoder.accept(hidden);
    mesh.visible = true;
    expect(encoder.encode(capture()).uploadedBytes, 0);
  });
  test('an unaccepted packet cannot advance the encoder baseline', () {
    final scene = Scene()..add(Mesh(BoxGeometry(), UnlitMaterial()));
    final encoder = ScenePacketEncoder(viewId: 7);
    final capture = FrameSubmission.capture(
      scene: scene,
      camera: PerspectiveCamera(),
      size: PhysicalSize(8, 8),
    );
    final failed = encoder.encode(capture);
    final retry = encoder.encode(capture);
    expect(retry.uploadedBytes, failed.uploadedBytes);
    expect(() => encoder.accept(failed), throwsStateError);
    encoder.accept(retry);
    expect(encoder.encode(capture).uploadedBytes, 0);
  });
}
