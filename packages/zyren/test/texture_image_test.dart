import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';

void main() {
  test('texture images own their pixels and validate complete mip levels', () {
    final pixels = Uint8List.fromList(List.filled(16, 128));
    final image = TextureImage.rgba(width: 2, height: 2, pixels: pixels);
    pixels[0] = 0;
    expect(image.levels.first[0], 128);
    expect(() => image.levels.first[0] = 0, throwsUnsupportedError);
    expect(
      () => TextureImage.rgba(width: 2, height: 2, pixels: Uint8List(15)),
      throwsArgumentError,
    );
    expect(() => TextureMap(image: image, uvSet: 2), throwsArgumentError);
    expect(
      () => BufferGeometry(
        positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
        normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
        indices: [0, 1, 2],
        uv0: [0, 0],
      ),
      throwsArgumentError,
    );
  });
  test('captured texture material is immutable and reused after hiding', () {
    final image = TextureImage.rgba(
      width: 1,
      height: 1,
      pixels: Uint8List.fromList([255, 0, 0, 255]),
    );
    final mesh = Mesh(
      PlaneGeometry(),
      UnlitMaterial(colorMap: TextureMap(image: image)),
    );
    final scene = Scene()..add(mesh);
    final encoder = ScenePacketEncoder(viewId: 1);
    FrameSubmission frame() => FrameSubmission.capture(
      scene: scene,
      camera: PerspectiveCamera(),
      size: PhysicalSize(16, 16),
    );
    final captured = frame();
    mesh.material = UnlitMaterial(colorMap: TextureMap(image: image, uvSet: 1));
    expect(frame, throwsArgumentError);
    final first = encoder.encode(captured);
    expect(first.uploadedBytes, 188);
    encoder.accept(first);
    mesh.material = UnlitMaterial(colorMap: TextureMap(image: image));
    mesh.visible = false;
    encoder.accept(encoder.encode(frame()));
    mesh.visible = true;
    expect(encoder.encode(frame()).uploadedBytes, 0);
    expect(() => frame().toNativePacket(), throwsUnsupportedError);
  });
}
