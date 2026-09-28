import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

Future<void> verifyHdr(NativeGpuBackend backend) async {
  final scope = backend.createResourceScope();
  final shaders = backend.createShaderCompiler();
  final compiler = backend.createGraphCompiler();
  try {
    final texture = await scope.createTexture(
      TextureDescriptor(
        width: 3,
        height: 5,
        mipLevels: 3,
        format: TextureFormat.rgba16Float,
        usage: {
          TextureUsage.copySource,
          TextureUsage.copyDestination,
          TextureUsage.storage,
        },
      ),
    );
    for (var mip = 0; mip < 3; mip++) {
      final bytes = Uint8List.fromList(
        List.generate(
          [120, 16, 8][mip],
          (i) => [0, 0x34, 0, 0x40, 0, 0x48, 0, 0x3c][i % 8],
        ),
      );
      await scope.writeTexture(texture, bytes, mipLevel: mip);
      expect(await scope.readTexture(texture, mipLevel: mip), bytes);
    }
    expect((await backend.resourceStats()).residentBytes, 144);
    final program = await shaders.compile(
      ShaderSource.wgsl('''
@group(0) @binding(0) var output: texture_storage_2d<rgba16float, write>;
@compute @workgroup_size(1) fn main() { textureStore(output, vec2(0), vec4(2.,4.,8.,.5)); }
'''),
    );
    final graph = await compiler.compile(
      GraphDescription(
        passes: [
          ComputePassDescriptor(
            name: 'HDR storage',
            program: program,
            workgroups: const Workgroups(1),
            writes: [texture],
            bindings: ShaderBindings([
              TextureBinding.storage(0, texture, mipLevel: 2),
            ]),
          ),
        ],
      ),
    );
    await graph.execute();
    expect(await scope.readTexture(texture, mipLevel: 2), [
      0,
      0x40,
      0,
      0x44,
      0,
      0x48,
      0,
      0x38,
    ]);
  } finally {
    await compiler.close();
    await shaders.close();
    await scope.close();
  }
  expect((await backend.resourceStats()).residentBytes, 0);
  final scene = Scene()..background = null;
  final mesh = scene.add(
    Mesh(
      BoxGeometry(),
      StandardMaterial(
        baseColor: const Color3(0, 0, 0),
        emissive: const Color3(.03125, .25, 1),
        emissiveIntensity: 8,
        alphaMode: MaterialAlphaMode.blend,
        opacity: .25,
        side: MaterialSide.front,
      ),
    ),
  );
  final camera = PerspectiveCamera()..position = const Vec3(0, 0, 3);
  Future<ReadbackOutput> draw(ColorPipeline? pipeline) async {
    final submission = FrameSubmission.capture(
      scene: scene,
      camera: camera,
      size: PhysicalSize(31, 31),
      colorPipeline: pipeline,
    );
    return await backend.render(submission) as ReadbackOutput;
  }

  void pixel(ReadbackOutput frame, List<int> expected) {
    final actual = frame.image.pixels.sublist(1920, 1924);
    for (var i = 0; i < 4; i++) {
      expect(
        actual[i],
        closeTo(expected[i], 2),
        reason: '$actual vs $expected',
      );
    }
  }

  pixel(await draw(ColorPipeline(toneMapping: ToneMapping.reinhard)), [
    124,
    213,
    242,
    64,
  ]);
  pixel(await draw(ColorPipeline()), [226, 242, 254, 64]);
  final dimmed = await draw(
    ColorPipeline(toneMapping: ToneMapping.linear, exposure: .25),
  );
  pixel(dimmed, [71, 188, 255, 64]);
  expect(dimmed.stats.uploadedBytes, 0);
  if (backend is NativeBackend) {
    final peer = backend.createView();
    try {
      pixel(
        await peer.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(31, 31),
                colorPipeline: ColorPipeline(toneMapping: ToneMapping.reinhard),
              ),
            )
            as ReadbackOutput,
        [124, 213, 242, 64],
      );
      pixel(
        await draw(
          ColorPipeline(toneMapping: ToneMapping.linear, exposure: .25),
        ),
        [71, 188, 255, 64],
      );
    } finally {
      await peer.close();
    }
  }
  pixel(await draw(null), [137, 255, 255, 64]);
  final effects = backend.createResourceScope();
  final effectShaders = backend.createShaderCompiler();
  final effectCompiler = backend.createGraphCompiler();
  try {
    final input = await effects.createTexture(
      TextureDescriptor(
        width: 31,
        height: 31,
        format: TextureFormat.rgba16Float,
        usage: {
          TextureUsage.sampled,
          TextureUsage.renderAttachment,
          TextureUsage.copySource,
        },
      ),
    );
    final output = await effects.createTexture(
      TextureDescriptor(
        width: 31,
        height: 31,
        format: TextureFormat.rgba16Float,
        usage: {TextureUsage.sampled, TextureUsage.renderAttachment},
      ),
    );
    final shader = await effectShaders.compile(
      ShaderSource.wgsl('''
@group(0) @binding(0) var input: texture_2d<f32>;
@vertex fn vertex(@builtin(vertex_index) i:u32) -> @builtin(position) vec4<f32> {
  let p = array<vec2<f32>,3>(vec2(-1.,-1.),vec2(3.,-1.),vec2(-1.,3.));
  return vec4(p[i],0.,1.);
}
@fragment fn fragment(@builtin(position) p:vec4<f32>) -> @location(0) vec4<f32> {
  let c = textureLoad(input,vec2<i32>(p.xy),0);
  return vec4(c.rgb * .5,c.a);
}
'''),
    );
    Future<CompiledGraph> build(GpuResource<GpuTexture> target) =>
        effectCompiler.compile(
          GraphDescription(
            sceneColor: input,
            output: target,
            passes: [
              RenderPassDescriptor(
                name: 'half light',
                program: shader,
                color: ColorAttachment(target),
                reads: [input],
                writes: [target],
                bindings: ShaderBindings([TextureBinding.sampled(0, input)]),
              ),
            ],
          ),
        );
    Future<ReadbackOutput> drawGraph(CompiledGraph graph) async =>
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(31, 31),
                graph: graph,
                colorPipeline: ColorPipeline(toneMapping: ToneMapping.reinhard),
              ),
            )
            as ReadbackOutput;
    pixel(await drawGraph(await build(output)), [94, 188, 231, 64]);
    final linear = await effects.readTexture(input);
    expect(linear.sublist(3840, 3848), [0, 0x34, 0, 0x40, 0, 0x48, 0, 0x34]);
    final clipped = await effects.createTexture(
      TextureDescriptor(
        width: 31,
        height: 31,
        usage: {TextureUsage.sampled, TextureUsage.renderAttachment},
      ),
    );
    await expectLater(drawGraph(await build(clipped)), throwsException);
    pixel(await drawGraph(await build(output)), [94, 188, 231, 64]);
  } finally {
    await effectCompiler.close();
    await effectShaders.close();
    await effects.close();
  }
  final custom = backend.createShaderCompiler();
  final original = mesh.material;
  try {
    final program = await custom.compileMesh(
      ShaderSource.wgsl('''
${MeshShaderInterface.wgsl}
@vertex fn vertex(@location(0) p:vec3<f32>) -> @builtin(position) vec4<f32> {
  return mesh.mvp * vec4(p,1.);
}
@fragment fn fragment() -> @location(0) vec4<f32> { return meshColor(vec4(.25,2.,8.,1.)); }
'''),
    );
    mesh.material = ShaderMaterial(
      program,
      side: MaterialSide.front,
      alphaMode: MaterialAlphaMode.blend,
      opacity: .25,
    );
    pixel(await draw(ColorPipeline(toneMapping: ToneMapping.reinhard)), [
      124,
      213,
      242,
      64,
    ]);
    pixel(await draw(null), [137, 255, 255, 64]);
  } finally {
    mesh.material = original;
    await custom.close();
  }
  scene.remove(mesh);
  await draw(null);
  expect((await backend.resourceStats()).residentBytes, 0);
}
