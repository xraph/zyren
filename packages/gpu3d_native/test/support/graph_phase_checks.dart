import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

const _prepare = '''
@group(0) @binding(0) var<uniform> tint: vec4<f32>;
@group(0) @binding(1) var output: texture_storage_2d<rgba8unorm, write>;
@compute @workgroup_size(2, 2) fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  textureStore(output, vec2<i32>(id.xy), tint);
}
''';
const _sample =
    '''
${MeshShaderInterface.wgsl}
@group(1) @binding(0) var source: texture_2d<f32>;
@vertex fn vertex(@location(0) p: vec3<f32>) -> @builtin(position) vec4<f32> {
  return mesh.mvp * vec4(p, 1.);
}
@fragment fn fragment() -> @location(0) vec4<f32> {
  return meshColor(textureLoad(source, vec2<i32>(0), 0));
}
''';
const _invert = '''
@group(0) @binding(0) var source: texture_2d<f32>;
@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  let p = array<vec2<f32>, 3>(vec2(-1., -1.), vec2(3., -1.), vec2(-1., 3.));
  return vec4(p[i], 0., 1.);
}
@fragment fn fragment(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
  return vec4(vec3(1.) - textureLoad(source, vec2<i32>(pixel.xy), 0).rgb, 1.);
}
''';

/// Exercises the same compute-to-material path through a native SceneView.
final class PreparedMaterialFixture extends ScenePlugin {
  @override
  String get id => 'test.prepared-material';
  @override
  Set<RenderFeature> get requiredFeatures => {
    RenderFeature.frameGraphs,
    RenderFeature.compute,
    RenderFeature.storageTextures,
    RenderFeature.meshShaders,
  };
  late GpuResource<Buffer> _tint;
  late ComputePassDescriptor _preparePass;
  Mesh? _mesh;
  @override
  Future<void> attach(PluginContext context) async {
    _tint = await context.resources.createBuffer(
      BufferDescriptor(
        size: 16,
        usage: {BufferUsage.uniform, BufferUsage.copyDestination},
      ),
    );
    await context.resources.writeBuffer(
      _tint,
      Float32List.fromList([0, 1, 0, 1]),
    );
    final generated = await context.resources.createTexture(
      TextureDescriptor(
        width: 2,
        height: 2,
        format: TextureFormat.rgba8Unorm,
        usage: {TextureUsage.storage, TextureUsage.sampled},
      ),
    );
    final compute = await context.shaders.compile(ShaderSource.wgsl(_prepare));
    final material = await context.shaders.compileMesh(
      ShaderSource.wgsl(_sample),
      bindings: ShaderBindings([
        TextureBinding.sampled(0, generated, group: 1),
      ]),
    );
    _preparePass = ComputePassDescriptor(
      name: 'prepare material',
      program: compute,
      workgroups: const Workgroups(1),
      reads: [_tint],
      writes: [generated],
      bindings: ShaderBindings([
        BufferBinding.uniform(0, _tint),
        TextureBinding.storage(1, generated),
      ]),
    );
    context.graph.addCompute(_preparePass, inputs: [_tint]);
    _mesh = context.scene.add(
      Mesh(PlaneGeometry(width: 2, height: 2), ShaderMaterial(material)),
    );
  }

  @override
  void detach(PluginContext context) {
    final mesh = _mesh;
    if (mesh != null) context.scene.remove(mesh);
    _mesh = null;
  }
}

Future<void> verifyGraphPhases(NativeGpuBackend backend) async {
  final resources = backend.createResourceScope();
  final shaders = backend.createShaderCompiler();
  final graphs = backend.createGraphCompiler();
  final scene = Scene()..background = const Color3(0, 0, 1);
  try {
    final tint = await resources.createBuffer(
      BufferDescriptor(
        size: 16,
        usage: {BufferUsage.uniform, BufferUsage.copyDestination},
      ),
    );
    final generated = await resources.createTexture(
      TextureDescriptor(
        width: 2,
        height: 2,
        format: TextureFormat.rgba8Unorm,
        usage: {TextureUsage.sampled, TextureUsage.storage},
      ),
    );
    Future<GpuResource<Texture>> color() => resources.createTexture(
      TextureDescriptor(
        width: 17,
        height: 13,
        usage: {TextureUsage.renderAttachment, TextureUsage.sampled},
      ),
    );
    final sceneColor = await color(), output = await color();
    final compute = await shaders.compile(ShaderSource.wgsl(_prepare));
    final invert = await shaders.compile(ShaderSource.wgsl(_invert));
    final material = await shaders.compileMesh(
      ShaderSource.wgsl(_sample),
      bindings: ShaderBindings([
        TextureBinding.sampled(0, generated, group: 1),
      ]),
    );
    final mesh = scene.add(
      Mesh(PlaneGeometry(width: 2, height: 2), ShaderMaterial(material)),
    );
    final prepare = ComputePassDescriptor(
      name: 'prepare material',
      program: compute,
      workgroups: const Workgroups(1),
      reads: [tint],
      writes: [generated],
      bindings: ShaderBindings([
        BufferBinding.uniform(0, tint),
        TextureBinding.storage(1, generated),
      ]),
    );
    final post = RenderPassDescriptor(
      name: 'invert',
      program: invert,
      color: ColorAttachment(output),
      reads: [sceneColor],
      writes: [output],
      bindings: ShaderBindings([TextureBinding.sampled(0, sceneColor)]),
    );
    Future<CompiledGraph> compile(bool effects) => graphs.compile(
      GraphDescription(
        sceneColor: sceneColor,
        output: effects ? output : sceneColor,
        inputs: [tint],
        beforeScene: [prepare],
        passes: [if (effects) post],
      ),
    );
    var graph = await compile(false);
    Future<ReadbackOutput> draw() async =>
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: PerspectiveCamera(),
                size: PhysicalSize(17, 13),
                graph: graph,
              ),
            )
            as ReadbackOutput;
    final center = (6 * 17 + 8) * 4;
    for (final color in [
      [1.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
      [1.0, 1.0, 1.0],
    ]) {
      await resources.writeBuffer(tint, Float32List.fromList([...color, 1]));
      final frame = await draw();
      expect(frame.image.pixels.sublist(center, center + 4), [
        ...color.map((v) => (v * 255).round()),
        255,
      ]);
      expect(frame.image.pixels.sublist(0, 4), [0, 0, 255, 255]);
      expect(frame.stats.computeDispatches, 1);
      expect(frame.stats.drawCalls, 2);
    }
    graph = await compile(true);
    await resources.writeBuffer(tint, Float32List.fromList([0, 1, 0, 1]));
    final finalFrame = await draw();
    expect(finalFrame.image.pixels.sublist(center, center + 4), [
      255,
      0,
      255,
      255,
    ]);
    expect(finalFrame.stats.computeDispatches, 1);
    expect(finalFrame.stats.drawCalls, 3);
    await resources.close();
    expect((await draw()).image.pixels.sublist(center, center + 4), [
      255,
      0,
      255,
      255,
    ]);
    scene.remove(mesh);
    await draw();
  } finally {
    await graphs.close();
    await shaders.close();
    await resources.close();
  }
  expect((await backend.resourceStats()).residentBytes, 0);
  expect((await backend.graphStats()).liveGraphs, 0);
  expect((await backend.graphStats()).liveMeshShaders, 0);
}
