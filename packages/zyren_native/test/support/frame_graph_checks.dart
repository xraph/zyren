import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

const frameEffect = '''
@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var rotated: texture_storage_2d<rgba8unorm, write>;
@compute @workgroup_size(8, 8) fn rotateCompute(@builtin(global_invocation_id) id: vec3<u32>) {
  if (any(id.xy >= textureDimensions(rotated))) { return; }
  textureStore(rotated, vec2<i32>(id.xy), vec4(textureLoad(source, vec2<i32>(id.xy), 0).brg, 1.));
}
@vertex fn vertex(@builtin(vertex_index) index: u32) -> @builtin(position) vec4<f32> {
  let positions = array<vec2<f32>, 3>(vec2(-1., -1.), vec2(3., -1.), vec2(-1., 3.));
  return vec4<f32>(positions[index], 0., 1.);
}
@fragment fn rotate(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
  return vec4(textureLoad(source, vec2<i32>(pixel.xy), 0).brg, 1.);
}
@fragment fn invert(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
  return vec4(vec3(1.) - textureLoad(source, vec2<i32>(pixel.xy), 0).rgb, 1.);
}
''';

Future<CompiledGraph> createFrameEffect(
  NativeGpuBackend backend,
  int width,
  int height, {
  bool compute = false,
}) async {
  final resources = backend.createResourceScope();
  final shaders = backend.createShaderCompiler();
  final compiler = backend.createGraphCompiler();
  try {
    return await compileFrameEffect(
      resources,
      shaders,
      compiler,
      width,
      height,
      compute: compute,
    );
  } finally {
    // The compiled graph owns the textures and programs used by later frames.
    await resources.close();
    await shaders.close();
  }
}

Future<void> verifyFrameGraph({
  NativeGpuBackend? providedBackend,
  bool compute = false,
}) async {
  final backend = providedBackend ?? await NativeBackend.create();
  try {
    final graph = await createFrameEffect(backend, 17, 13, compute: compute);
    final scene = Scene()..background = const Color3(1, 0, 0);
    Future<ReadbackOutput> render() async =>
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: PerspectiveCamera(),
                size: PhysicalSize(17, 13),
                graph: graph,
              ),
            )
            as ReadbackOutput;
    final first = await render();
    final profile = first.stats.profile!;
    expect(profile.status, 'complete');
    expect(profile.passes['resourceGraphAfter']!.executed, isTrue);
    expect(profile.passes['scene']!.executed, isTrue);
    expect(profile.passes['output']!.executed, isTrue);
    expect(profile.submissionCount, 1);
    expect(first.stats.drawCalls, compute ? 2 : 3);
    expect(first.stats.computeDispatches, compute ? 1 : 0);
    expect(first.stats.triangles, compute ? 2 : 3);
    for (var i = 0; i < first.image.pixels.length; i += 4) {
      expect(first.image.pixels.sublist(i, i + 4), [255, 0, 255, 255]);
    }
    scene.background = const Color3(0, 0, 1);
    final second = await render();
    expect(second.image.pixels.sublist(0, 4), [0, 255, 255, 255]);
    scene.background = const Color3(.25, .5, .75);
    final linear = await render();
    for (var i = 0; i < 3; i++) {
      expect(linear.image.pixels[i], closeTo([137, 225, 188][i], 2));
    }
    scene.background = const Color3(0, 0, 1);
    final box = Mesh(
      BoxGeometry(),
      UnlitMaterial(color: const Color3(1, 0, 0)),
    );
    scene.add(box);
    final mesh = await render();
    final center = (6 * 17 + 8) * 4;
    expect(mesh.image.pixels.sublist(center, center + 4), [255, 0, 255, 255]);
    expect(mesh.stats.drawCalls, compute ? 3 : 4);
    await expectLater(
      backend.render(
        FrameSubmission.capture(
          scene: scene,
          camera: PerspectiveCamera(),
          size: PhysicalSize(18, 13),
          graph: graph,
        ),
      ),
      throwsA(isA<GraphException>()),
    );
    expect((await render()).image.pixels.sublist(center, center + 4), [
      255,
      0,
      255,
      255,
    ]);
    scene.remove(box);
    // Render removal before checking the graph's final allocation cleanup.
    await render();
    await graph.close();
    expect((await backend.resourceStats()).residentBytes, 0);
    expect((await backend.graphStats()).liveGraphs, 0);
    final plain =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: PerspectiveCamera(),
                size: PhysicalSize(17, 13),
              ),
            )
            as ReadbackOutput;
    expect(plain.image.pixels.sublist(0, 4), [0, 0, 255, 255]);
  } finally {
    await backend.close();
  }
}

Future<CompiledGraph> compileFrameEffect(
  ResourceScope resources,
  ShaderCompiler shaders,
  GraphCompiler compiler,
  int width,
  int height, {
  bool compute = false,
}) async {
  Future<GpuResource<Texture>> texture(String label) => resources.createTexture(
    TextureDescriptor(
      label: label,
      width: width,
      height: height,
      usage: {
        TextureUsage.renderAttachment,
        TextureUsage.sampled,
        TextureUsage.copySource,
      },
    ),
  );
  final sceneColor = await texture('scene color');
  final intermediate = compute
      ? await resources.createTexture(
          TextureDescriptor(
            width: width,
            height: height,
            format: TextureFormat.rgba8Unorm,
            usage: {TextureUsage.storage, TextureUsage.sampled},
          ),
        )
      : await texture('rotated');
  final output = await texture('inverted');
  final program = await shaders.compile(ShaderSource.wgsl(frameEffect));
  RenderPassDescriptor pass(
    String name,
    GpuResource<Texture> source,
    GpuResource<Texture> target,
  ) => RenderPassDescriptor(
    name: name,
    program: program,
    fragmentEntryPoint: name,
    color: ColorAttachment(target),
    bindings: ShaderBindings([TextureBinding.sampled(0, source)]),
    reads: [source],
    writes: [target],
  );
  return await compiler.compile(
    GraphDescription(
      sceneColor: sceneColor,
      output: output,
      passes: [
        if (compute)
          ComputePassDescriptor(
            name: 'rotate compute',
            program: program,
            entryPoint: 'rotateCompute',
            workgroups: Workgroups((width + 7) ~/ 8, (height + 7) ~/ 8),
            bindings: ShaderBindings([
              TextureBinding.sampled(0, sceneColor),
              TextureBinding.storage(1, intermediate),
            ]),
            reads: [sceneColor],
            writes: [intermediate],
          )
        else
          pass('rotate', sceneColor, intermediate),
        pass('invert', intermediate, output),
      ],
    ),
  );
}
