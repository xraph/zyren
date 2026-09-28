import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';

void main() {
  test(
    'data maps require linear storage and preserve material configuration',
    () {
      final srgb = TextureMap(
        image: TextureImage.rgba(
          width: 1,
          height: 1,
          pixels: Uint8List.fromList([128, 128, 255, 255]),
        ),
      );
      final linear = TextureMap(
        image: TextureImage.rgba(
          width: 1,
          height: 1,
          format: TextureFormat.rgba8Unorm,
          pixels: Uint8List.fromList([128, 128, 255, 255]),
        ),
      );
      expect(() => StandardMaterial(normalMap: srgb), throwsArgumentError);
      expect(
        () => StandardMaterial(metallicRoughnessMap: srgb),
        throwsArgumentError,
      );
      expect(() => StandardMaterial(occlusionMap: srgb), throwsArgumentError);
      expect(() => StandardMaterial(occlusionStrength: 2), throwsArgumentError);
      final material = StandardMaterial(
        normalMap: linear,
        metallicRoughnessMap: linear,
        occlusionMap: linear,
        emissiveMap: srgb,
        normalScaleY: -1,
      );
      final copy = material.copyWith(color: const Color3(1, 0, 0));
      expect(copy.normalMap, same(linear));
      expect(copy.emissiveMap, same(srgb));
      expect(copy.normalScaleY, -1);
      final missingUv = Scene()
        ..add(
          Mesh(
            PlaneGeometry(),
            StandardMaterial(
              normalMap: TextureMap(image: linear.image, uvSet: 1),
            ),
          ),
        );
      expect(
        () => FrameSubmission.capture(
          scene: missingUv,
          camera: PerspectiveCamera(),
          size: PhysicalSize(16, 16),
        ),
        throwsArgumentError,
      );
      final scene = Scene()..add(Mesh(PlaneGeometry(), material));
      final frame = FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(16, 16),
      );
      expect(
        ScenePacketEncoder(viewId: 1).encode(frame).uploadedBytes,
        greaterThan(0),
      );
    },
  );
}
