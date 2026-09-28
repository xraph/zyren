import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:shader_lab_effects/shader_lab_effects.dart';
import 'package:test/test.dart';
import 'native_checks.dart' show ObservedBackend;

Future<void> verifyTemporalHistory(NativeGpuBackend backend) async {
  final firstView = ObservedBackend(backend),
      otherView = ObservedBackend(backend);
  final first = TemporalBlendPlugin(enabled: true, retention: .5);
  final other = TemporalBlendPlugin(enabled: true, retention: .5);
  final scene = Scene()..background = const Color3(1, 0, 0);
  final camera = PerspectiveCamera();
  final engine = await SceneEngine.create(
    scene: scene,
    camera: camera,
    backendFactory: () async => firstView,
    plugins: [first],
  );
  final second = await SceneEngine.create(
    scene: Scene()..background = const Color3(0, 0, 1),
    camera: PerspectiveCamera(),
    backendFactory: () async => otherView,
    plugins: [other],
  );
  Future<ReadbackOutput> draw(SceneEngine engine, [int width = 17]) async =>
      await engine.renderFrame(elapsed: Duration.zero, width: width, height: 13)
          as ReadbackOutput;
  void pixel(ReadbackOutput output, List<int> expected) {
    final actual = output.image.pixels.sublist(0, 4);
    for (var i = 0; i < 4; i++) {
      expect(
        actual[i],
        closeTo(expected[i], 2),
        reason: '$actual vs $expected',
      );
    }
  }

  try {
    pixel(await draw(engine), [255, 0, 0, 255]);
    pixel(await draw(second), [0, 0, 255, 255]);
    final compiled = (await backend.graphStats()).pipelineCompilations;
    expect((await backend.graphStats()).liveGraphs, 4);
    scene.background = const Color3(0, 1, 0);
    camera.position = const Vec3(1, 0, 5);
    pixel(await draw(engine), [188, 188, 0, 255]);
    scene.background = const Color3(0, 0, 1);
    pixel(await draw(engine), [137, 137, 188, 255]);
    expect(first.historyFrames, 3);
    pixel(await draw(second), [0, 0, 255, 255]);
    expect((await backend.graphStats()).pipelineCompilations, compiled);
    camera.fieldOfView = .7;
    pixel(await draw(engine), [0, 0, 255, 255]);
    expect(first.historyFrames, 1);
    scene.background = const Color3(1, 0, 0);
    first.reset();
    pixel(await draw(engine), [255, 0, 0, 255]);
    scene.background = const Color3(0, 1, 0);
    pixel(await draw(engine, 23), [0, 255, 0, 255]);
    first.enabled = false;
    scene.background = const Color3(0, 0, 1);
    pixel(await draw(engine), [0, 0, 255, 255]);
    expect((await backend.graphStats()).liveGraphs, 2);
    first.enabled = true;
    scene.background = const Color3(1, 0, 0);
    scene.backgroundOpacity = .5;
    pixel(await draw(engine), [255, 0, 0, 128]);
    scene.background = null;
    pixel(await draw(engine), [255, 0, 0, 64]);
    first.reset();
    pixel(await draw(engine), [0, 0, 0, 0]);
    await engine.dispose();
    pixel(await draw(second), [0, 0, 255, 255]);
    await second.dispose();
    expect((await backend.graphStats()).liveGraphs, 0);
    expect((await backend.resourceStats()).residentBytes, 0);
    expect((await backend.shaderStats()).livePrograms, 0);
  } finally {
    await engine.dispose();
    await second.dispose();
  }
}

class _ComputeHistory extends ScenePlugin {
  @override
  String get id => 'test.compute-history';
  @override
  Future<void> attach(PluginContext context) async {
    final shader = await context.shaders.compile(
      ShaderSource.wgsl('''
${TextureHistory.wgsl}
@group(0) @binding(0) var previous: texture_2d<f32>;
@group(0) @binding(1) var current: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(2) var<uniform> history: TextureHistoryState;
@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  if (any(id.xy >= textureDimensions(current))) { return; }
  var old = 0.;
  if (history.validFrames > 0u) { old = textureLoad(previous, vec2<i32>(id.xy), 0).r; }
  textureStore(current, vec2<i32>(id.xy), vec4(old + .25, 0., 0., 1.));
}
'''),
    );
    context.graph.addEffect(
      name: id,
      build: (frame) async {
        final history = await frame.createHistory(
          format: TextureFormat.rgba8Unorm,
          usage: {TextureUsage.sampled, TextureUsage.storage},
        );
        final alias = await frame.resources.retain(history.previous);
        return GraphEffect(
          output: history.current,
          passes: [
            ComputePassDescriptor(
              name: id,
              program: shader,
              workgroups: Workgroups(
                (frame.size.width + 7) ~/ 8,
                (frame.size.height + 7) ~/ 8,
              ),
              bindings: ShaderBindings([
                TextureBinding.sampled(0, alias),
                TextureBinding.storage(1, history.current),
                BufferBinding.uniform(2, history.uniforms),
              ]),
              reads: [alias, history.uniforms],
              writes: [history.current],
            ),
          ],
        );
      },
    );
  }
}

Future<void> verifyComputeHistory(NativeGpuBackend backend) async {
  final engine = await SceneEngine.create(
    scene: Scene(),
    camera: PerspectiveCamera(),
    backendFactory: () async => ObservedBackend(backend),
    plugins: [_ComputeHistory()],
  );
  try {
    for (final red in [137, 188, 225]) {
      final output =
          await engine.renderFrame(
                elapsed: Duration.zero,
                width: 17,
                height: 13,
              )
              as ReadbackOutput;
      expect(output.image.pixels[0], closeTo(red, 2));
      expect(output.image.pixels.sublist(1, 4), [0, 0, 255]);
      expect(output.stats.computeDispatches, 1);
    }
  } finally {
    await engine.dispose();
  }
  expect((await backend.graphStats()).liveGraphs, 0);
  expect((await backend.resourceStats()).residentBytes, 0);
}
