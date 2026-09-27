import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';

void main() {
  final mesh = Mesh(BoxGeometry(), UnlitMaterial());
  final scene = Scene()..add(mesh);
  final encoder = ScenePacketEncoder(viewId: 1);
  FrameSubmission capture() => FrameSubmission.capture(
    scene: scene,
    camera: PerspectiveCamera(),
    size: PhysicalSize(31, 31),
  );
  final first = encoder.encode(capture());
  if (first.uploadedBytes != 720 || first.changedMeshes != 1) {
    throw StateError('First frame did not include the box.');
  }
  encoder.accept(first);
  mesh.position = const Vec3(1, 0, 0);
  final delta = encoder.encode(capture());
  if (delta.uploadedBytes != 0 || delta.changedMeshes != 1) {
    throw StateError('Transform edit did not use a geometry-free delta.');
  }
  encoder.accept(delta);
  if (encoder.encode(capture()).changedMeshes != 0) {
    throw StateError('An unchanged scene produced mesh updates.');
  }
  mesh.visible = false;
  encoder.accept(encoder.encode(capture()));
  mesh.visible = true;
  if (encoder.encode(capture()).uploadedBytes != 0) {
    throw StateError('Hidden geometry was uploaded again.');
  }
  print('AOT scene encoding passed.');
}
