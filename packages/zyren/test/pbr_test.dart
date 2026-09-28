import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';

void main() {
  test('standard material and physical light parameters are bounded', () {
    expect(() => StandardMaterial(metallic: -1), throwsArgumentError);
    expect(() => StandardMaterial(roughness: double.nan), throwsArgumentError);
    expect(() => PointLight(intensity: -1), throwsArgumentError);
    expect(() => SpotLight(angle: 2), throwsArgumentError);
    final material = StandardMaterial(
      baseColor: const Color3(.5, .2, .1),
      metallic: .8,
      roughness: .3,
      emissive: const Color3(1, 0, 0),
      emissiveIntensity: 4,
    );
    expect(material.copyWith(color: const Color3(0, 1, 0)).metallic, .8);
    final scene = Scene()
      ..add(Mesh(PlaneGeometry(), material))
      ..add(DirectionalLight(direction: const Vec3(0, 0, -1), intensity: 3));
    final capture = FrameSubmission.capture(
      scene: scene,
      camera: PerspectiveCamera(),
      size: PhysicalSize(16, 16),
    );
    expect(capture.toNativePacket, throwsUnsupportedError);
    expect(ScenePacketEncoder(viewId: 1).encode(capture).bytes, isNotEmpty);
  });
}
