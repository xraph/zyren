import 'dart:typed_data';
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
  if (first.uploadedBytes != 1104 || first.changedMeshes != 1) {
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
  final image = TextureImage.rgba(
    width: 2,
    height: 2,
    generateMipmaps: true,
    pixels: Uint8List.fromList([
      for (var i = 0; i < 4; i++) ...[255, 0, 0, 255],
    ]),
  );
  scene.remove(mesh);
  final plane = scene.add(
    Mesh(
      PlaneGeometry(dynamic: true, indexFormat: IndexFormat.uint16),
      UnlitMaterial(
        colorMap: TextureMap(image: image),
        alphaMode: MaterialAlphaMode.blend,
        opacity: .5,
      ),
    ),
  );
  final textureEncoder = ScenePacketEncoder(viewId: 2);
  final textureFrame = textureEncoder.encode(capture());
  if (textureFrame.uploadedBytes != 188) {
    throw StateError('First textured frame lost its image or UV buffer.');
  }
  textureEncoder.accept(textureFrame);
  plane.material = UnlitMaterial(
    colorMap: TextureMap(
      image: image,
      sampler: const SamplerDescriptor(wrapU: TextureWrap.repeat),
    ),
  );
  final samplerEdit = textureEncoder.encode(capture());
  if (samplerEdit.uploadedBytes != 0 || samplerEdit.changedMeshes != 1) {
    throw StateError('Sampler edit did not retain the image.');
  }
  textureEncoder.accept(samplerEdit);
  plane.geometry.updateAttribute(
    VertexSemantic.position,
    Float32List.fromList([-1, -1, 0]),
  );
  final geometryEdit = textureEncoder.encode(capture());
  if (geometryEdit.uploadedBytes != 24) {
    throw StateError('Dynamic geometry lost its dirty range.');
  }
  textureEncoder.accept(geometryEdit);
  if (textureEncoder.encode(capture()).uploadedBytes != 0) {
    throw StateError('Dynamic geometry repeated an accepted upload.');
  }
  final points = scene.add(
    Points(PointGeometry(points: [Vec3.zero]), PointsMaterial(size: 12)),
  );
  final primitive = textureEncoder.encode(capture());
  if (primitive.uploadedBytes != 120 || primitive.changedMeshes != 2) {
    throw StateError(
      'Point expansion did not preserve the triangle resources.',
    );
  }
  textureEncoder.accept(primitive);
  points.material = points.material.copyWith(size: 20);
  final sizeEdit = textureEncoder.encode(capture());
  if (sizeEdit.uploadedBytes != 0 || sizeEdit.changedMeshes != 1) {
    throw StateError('Point size edit reuploaded geometry.');
  }
  print('AOT scene encoding passed.');
}
