import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:shader_lab_effects/shader_lab_effects.dart';
import 'package:test/test.dart';

int srgb(double linear) =>
    ((linear <= .0031308
                ? linear * 12.92
                : 1.055 * math.pow(linear, 1 / 2.4) - .055) *
            255)
        .round();

/// Keep a test observer alive while the engine releases its attachment owners.
class ObservedBackend implements GraphBackend {
  final NativeGpuBackend backend;
  ObservedBackend(this.backend);
  @override
  DeviceCapabilities get capabilities => backend.capabilities;
  @override
  ResourceScope createResourceScope({String label = ''}) =>
      backend.createResourceScope(label: label);
  @override
  ShaderCompiler createShaderCompiler({String label = ''}) =>
      backend.createShaderCompiler(label: label);
  @override
  GraphCompiler createGraphCompiler({String label = ''}) =>
      backend.createGraphCompiler(label: label);
  @override
  Future<FrameOutput> render(FrameSubmission frame) => backend.render(frame);
  @override
  Future<void> close() async {}
}

Future<void> verifyEffects(NativeGpuBackend backend) async {
  final effects = EffectsPlugin(
    options: EffectsOptions(saturation: 0, vignette: 0),
  );
  final scene = Scene()..background = const Color3(1, 0, 0);
  final camera = PerspectiveCamera();
  final engine = await SceneEngine.create(
    scene: scene,
    camera: camera,
    backendFactory: () async => ObservedBackend(backend),
    plugins: [effects],
  );
  try {
    Future<ReadbackOutput> draw(int w, int h) async =>
        await engine.renderFrame(elapsed: Duration.zero, width: w, height: h)
            as ReadbackOutput;
    var builds = 0;
    for (final (w, h) in [(17, 13), (29, 7), (9, 31), (1, 1), (17, 13)]) {
      final frame = await draw(w, h);
      for (var i = 0; i < w * h; i++) {
        for (var c = 0; c < 3; c++) {
          expect(frame.image.pixels[i * 4 + c], closeTo(srgb(.2126), 2));
        }
        expect(frame.image.pixels[i * 4 + 3], 255);
      }
      expect(frame.stats.drawCalls, 3);
      expect(effects.state.graphBuilds, ++builds);
      expect((await backend.resourceStats()).residentBytes, 16 + 12 * w * h);
      expect((await backend.graphStats()).liveGraphs, 1);
    }
    effects.options = EffectsOptions(saturation: 1, vignette: 1);
    final vignette = await draw(17, 13);
    expect(effects.state.graphBuilds, builds);
    final center = (6 * 17 + 8) * 4;
    expect(vignette.image.pixels[center], 255);
    expect(vignette.image.pixels.first, lessThan(115));
    expect(vignette.image.pixels[1], 0);
    expect((await backend.graphStats()).cachedPipelines, 2);

    // Spatial passes must only use the current frame after a cut or projection edit.
    scene.background = const Color3(0, 0, 1);
    camera.position = const Vec3(4, 3, 8);
    camera.fieldOfView = Angle.degrees(35);
    final cut = await draw(17, 13);
    expect(cut.image.pixels.sublist(center, center + 4), [0, 0, 255, 255]);
    effects.options = effects.options.copyWith(enabled: false);
    final bypass = await draw(7, 9);
    expect(bypass.stats.drawCalls, 0);
    expect(bypass.image.pixels.sublist(0, 4), [0, 0, 255, 255]);
    expect(effects.state.graphBuilds, builds);
    effects.options = EffectsOptions(exposure: -1, vignette: 0);
    final enabled = await draw(7, 9);
    expect(enabled.image.pixels[2], closeTo(srgb(.5), 2));
    expect(effects.state.graphBuilds, builds + 1);
  } finally {
    await engine.dispose();
  }
  expect(effects.state.availability, EffectsAvailability.detached);
  expect((await backend.resourceStats()).residentBytes, 0);
  expect((await backend.graphStats()).liveGraphs, 0);
  expect((await backend.graphStats()).cachedPipelines, 0);
  expect((await backend.shaderStats()).livePrograms, 0);
}
