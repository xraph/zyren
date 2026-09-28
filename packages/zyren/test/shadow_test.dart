import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';

void main() {
  test('shadow flags participate in immutable frame deltas', () {
    final scene = Scene();
    final mesh = scene.add(
      Mesh(BoxGeometry(), StandardMaterial())..castShadow = true,
    );
    final light = scene.add(
      DirectionalLight(shadow: ShadowSettings(cascades: 4)),
    );
    final camera = PerspectiveCamera();
    FrameSubmission capture() => FrameSubmission.capture(
      scene: scene,
      camera: camera,
      size: PhysicalSize(32, 32),
    );
    final encoder = ScenePacketEncoder(viewId: 100);
    final original = capture();
    final first = encoder.encode(original);
    encoder.accept(first);
    mesh.receiveShadow = false;
    final changed = encoder.encode(capture());
    expect(changed.changedMeshes, 1);
    expect(changed.uploadedBytes, 0);
    encoder.accept(changed);
    final saved = encoder.encode(original);
    expect(saved.changedMeshes, 1);
    encoder.accept(saved);
    light.shadow = null;
    scene.remove(light);
    mesh.castShadow = false;
    expect(capture().toNativePacket, throwsUnsupportedError);
    mesh.material = UnlitMaterial();
    mesh.receiveShadow = true;
    expect(capture().toNativePacket()['meshes'], hasLength(1));
  });
  test('shadow settings bound work and reject unsupported light profiles', () {
    expect(() => ShadowSettings(cascades: 5), throwsArgumentError);
    expect(() => ShadowSettings(resolution: 8192), throwsArgumentError);
    expect(() => ShadowSettings(near: 1, maxDistance: 1), throwsArgumentError);
    expect(() => ShadowSettings(normalBias: double.nan), throwsArgumentError);
    expect(
      () => SpotLight(shadow: ShadowSettings(cascades: 2)),
      throwsArgumentError,
    );
    final scene = Scene();
    final hemi = scene.add(HemisphereLight()..shadow = ShadowSettings());
    FrameSubmission capture() => FrameSubmission.capture(
      scene: scene,
      camera: PerspectiveCamera(),
      size: PhysicalSize(16, 16),
    );
    expect(capture, throwsUnsupportedError);
    scene.remove(hemi);
    for (var i = 0; i < 3; i++) {
      scene.add(DirectionalLight(shadow: ShadowSettings(cascades: 4)));
    }
    expect(capture, throwsArgumentError);
  });
}
