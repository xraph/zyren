import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'material_compiler_test.dart' as fixture;

void main() {
  test(
    'effect frames capture output settings and reject stale owners',
    () async {
      final device = fixture.Device();
      final programs = ShaderCompiler(device),
          materials = MaterialCompiler(device);
      final effect = await materials.compileEffect(
        PostProcessDescriptor(
          program: await programs.compile(ShaderSource.wgsl('valid')),
        ),
      );
      final scene = Scene()
        ..renderSettings = RenderSettings(
          effects: [effect],
          toneMapping: ToneMapping.aces,
          exposure: 2,
          backgroundAlpha: .5,
          historyEpoch: 3,
        );
      final frame = FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(32, 32),
      );
      final registration = scene.addEffect(effect);
      scene.renderSettings = scene.renderSettings.copyWith(exposure: 3);
      expect(scene.effects, hasLength(2));
      registration.dispose();
      expect(scene.effects, hasLength(1));
      final screenShader = await materials.compile(
        PostProcessDescriptor(
          program: await programs.compile(ShaderSource.wgsl('valid')),
        ),
      );
      expect(() => ShaderMaterial(screenShader), throwsArgumentError);
      scene.renderSettings = RenderSettings();
      expect(
        () => ScenePacketEncoder(viewId: 1).encode(frame),
        throwsUnsupportedError,
      );
      final encoder = ScenePacketEncoder(viewId: 1, materialDevice: device);
      expect(encoder.encode(frame).bytes, isNotEmpty);
      expect(frame.toNativePacket, throwsUnsupportedError);
      await materials.close();
      expect(() => encoder.encode(frame), throwsStateError);
      await programs.close();
    },
  );
  test('render settings bound exposure, alpha and effect counts', () {
    expect(() => RenderSettings(exposure: double.nan), throwsArgumentError);
    expect(() => RenderSettings(backgroundAlpha: 1.1), throwsArgumentError);
    expect(() => RenderSettings(historyEpoch: -1), throwsArgumentError);
  });
}
