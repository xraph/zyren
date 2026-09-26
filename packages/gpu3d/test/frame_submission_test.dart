import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';

void main() {
  test(
    'submission freezes transforms, camera and geometry for async rendering',
    () {
      final scene = Scene();
      final mesh = Mesh(BoxGeometry(), UnlitMaterial());
      scene.add(mesh);
      final camera = PerspectiveCamera();
      final submission = FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(64, 64),
      );
      mesh.position = const Vec3(10, 0, 0);
      camera.position = const Vec3(20, 0, 5);
      scene.background = const Color3(1, 1, 1);
      final packet = submission.toNativePacket();
      final model = ((packet['meshes'] as List).single as Map)['model'] as List;
      expect(model[12], 0);
      expect(model[14], -5);
      expect(submission.camera.origin, [0, 0, 5]);
      expect(() => model[12] = 999, throwsUnsupportedError);
      expect(() => submission.camera.origin[0] = 999, throwsUnsupportedError);
      expect(submission.scene.triangles, 12);
      expect(submission.scene.drawCalls, 1);
      expect(
        submission.toNativePacket(uploaded: {mesh.geometry.id})['geometries'],
        isEmpty,
      );
      expect(submission.toNativePacket()['geometries'], hasLength(1));
    },
  );

  test(
    'physical size and image storage reject invalid input before submission',
    () {
      expect(() => PhysicalSize(0, 1), throwsArgumentError);
      expect(() => PhysicalSize(1, -1), throwsArgumentError);
      expect(
        () => ImageData(pixels: Uint8List(3), size: PhysicalSize(1, 1)),
        throwsArgumentError,
      );
      expect(
        () => ImageData(
          pixels: Uint8List(8),
          size: PhysicalSize(2, 1),
          rowStride: 4,
        ),
        throwsArgumentError,
      );
      final image = ImageData(
        pixels: Uint8List(24),
        size: PhysicalSize(2, 2),
        rowStride: 12,
      );
      expect(image.rowStride, 12);
      expect(image.colorSpace, ColorSpace.srgb);
      expect(image.alphaMode, AlphaMode.straight);
    },
  );
  test('image validation cannot accept overflowing row or height products', () {
    expect(
      () => ImageData(pixels: Uint8List(0), size: PhysicalSize(1 << 62, 1)),
      throwsArgumentError,
    );
    expect(
      () => ImageData(pixels: Uint8List(0), size: PhysicalSize(1, 1 << 62)),
      throwsArgumentError,
    );
  });
}
