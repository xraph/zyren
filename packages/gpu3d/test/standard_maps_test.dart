import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';

TextureMap map({int uvSet = 0, bool srgb = false}) => TextureMap(
  image: TextureImage.rgba(
    width: 1,
    height: 1,
    pixels: Uint8List.fromList([128, 128, 255, 255]),
    format: srgb ? TextureFormat.rgba8UnormSrgb : TextureFormat.rgba8Unorm,
  ),
  uvSet: uvSet,
);
FrameSubmission frame(Scene scene) => FrameSubmission.capture(
  scene: scene,
  camera: PerspectiveCamera(),
  size: PhysicalSize(31, 31),
);

void main() {
  test(
    'hemisphere lights freeze colors, orientation and independent limits',
    () {
      final scene = Scene();
      final light = scene.add(
        HemisphereLight(groundColor: const Color3(.1, .2, .3)),
      );
      final captured = frame(scene).toNativePacket()['hemispheres'] as List;
      expect((captured.single as Map)['direction'], [0.0, 1.0, 0.0]);
      final revision = scene.revision;
      light.groundColor = const Color3(.3, .2, .1);
      expect(scene.revision, greaterThan(revision));
      expect((captured.single as Map)['ground_color'], [.1, .2, .3]);
      for (var i = 0; i < 4; i++) {
        scene.add(HemisphereLight());
      }
      expect(() => frame(scene), throwsArgumentError);
      light.visible = false;
      expect(frame(scene).scene.hemisphereLightCount, 4);
    },
  );
  test('standard maps preserve values and reject nonlinear data', () {
    final linear = map();
    final material = StandardMaterial(
      normalMap: linear,
      metallicRoughnessMap: linear,
      occlusionMap: linear,
      emissiveMap: map(srgb: true),
      normalScale: .5,
      occlusionStrength: .75,
    );
    final next = material.copyWith(roughness: .3, clearNormalMap: true);
    expect(next.normalMap, isNull);
    expect(next.metallicRoughnessMap, same(linear));
    expect(next.occlusionMap, same(linear));
    expect(next.normalScale, .5);
    expect(next.occlusionStrength, .75);
    expect(material.copyWith(occlusionStrength: 0).occlusionStrength, 0.0);
    expect(
      () => StandardMaterial(normalMap: map(srgb: true)),
      throwsArgumentError,
    );
    expect(
      () => StandardMaterial(metallicRoughnessMap: map(srgb: true)),
      throwsArgumentError,
    );
    expect(
      () => StandardMaterial(occlusionMap: map(srgb: true)),
      throwsArgumentError,
    );
    expect(
      () => StandardMaterial(normalScale: double.nan),
      throwsArgumentError,
    );
    expect(() => StandardMaterial(occlusionStrength: 1.1), throwsArgumentError);
  });
  test('channel bindings validate their own UV set and enter frame deltas', () {
    final scene = Scene();
    final image = map(uvSet: 1);
    var mesh = scene.add(
      Mesh(PlaneGeometry(), StandardMaterial(emissiveMap: image)),
    );
    expect(() => frame(scene), throwsArgumentError);
    final geometry = mesh.geometry;
    scene.remove(mesh);
    mesh = scene.add(
      Mesh(
        BufferGeometry(
          positions: geometry.positions,
          normals: geometry.normals,
          indices: geometry.indices,
          uv0: geometry.uv0,
          uv1: geometry.uv0,
        ),
        mesh.material,
      ),
    );
    final encoder = ScenePacketEncoder(viewId: 1);
    final first = encoder.encode(frame(scene));
    encoder.accept(first);
    mesh.material = (mesh.material as StandardMaterial).copyWith(
      normalMap: image,
      normalScale: .2,
    );
    final second = encoder.encode(frame(scene));
    expect(second.changedMeshes, 1);
    expect(second.uploadedBytes, 0);
    encoder.accept(second);
    mesh.material = (mesh.material as StandardMaterial).copyWith(
      clearNormalMap: true,
      clearEmissiveMap: true,
    );
    expect(encoder.encode(frame(scene)).changedMeshes, 1);
  });
  test('explicit tangents upload and update as a separate bounded stream', () {
    final plane = PlaneGeometry();
    final tangents = Float32List.fromList([
      for (var i = 0; i < plane.vertexCount; i++) ...[1.0, 0.0, 0.0, 1.0],
    ]);
    final geometry = BufferGeometry.fromAttributes(
      attributes: {
        ...plane.attributes,
        VertexSemantic.tangent: VertexAttribute(
          tangents,
          format: VertexFormat.float32x4,
        ),
      },
      indices: plane.indices,
      dynamic: true,
    );
    final scene = Scene()
      ..add(Mesh(geometry, StandardMaterial(normalMap: map())));
    final encoder = ScenePacketEncoder(viewId: 1);
    final first = encoder.encode(frame(scene));
    expect(
      first.uploadedBytes,
      plane.capture().gpuByteLength + tangents.lengthInBytes + 4,
    );
    encoder.accept(first);
    geometry.updateAttribute(
      VertexSemantic.tangent,
      Float32List.fromList([1, 0, 0, -1]),
      firstVertex: 0,
    );
    expect(encoder.encode(frame(scene)).uploadedBytes, 16);
  });
}
