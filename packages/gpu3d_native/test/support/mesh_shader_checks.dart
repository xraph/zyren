import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'frame_graph_checks.dart' show createFrameEffect, frameEffect;

const textureMesh =
    '''
${MeshShaderInterface.wgsl}
@group(3) @binding(0) var source: texture_2d<f32>;
@group(3) @binding(1) var sourceSampler: sampler;
struct Vertex {
  @builtin(position) position: vec4<f32>,
  @location(0) uv: vec2<f32>,
};
@vertex fn vertex(@location(0) p: vec3<f32>, @location(2) uv: vec2<f32>) -> Vertex {
  return Vertex(mesh.mvp * vec4(p, 1.), uv);
}
@fragment fn fragment(input: Vertex) -> @location(0) vec4<f32> {
  return meshColor(textureSample(source, sourceSampler, input.uv));
}
''';

Future<void> verifyMeshShaders(NativeGpuBackend backend) async {
  final resources = backend.createResourceScope();
  final shaders = backend.createShaderCompiler();
  final scene = Scene()..background = const Color3(0, 0, 1);
  final camera = PerspectiveCamera();
  final center = (6 * 17 + 8) * 4;
  Future<ReadbackOutput> draw({CompiledGraph? graph}) async =>
      await backend.render(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(17, 13),
              graph: graph,
            ),
          )
          as ReadbackOutput;
  List<int> pixel(ReadbackOutput frame) =>
      frame.image.pixels.sublist(center, center + 4);
  CompiledGraph? effect;
  try {
    final texture = await resources.createTexture(
      TextureDescriptor(
        width: 2,
        height: 2,
        usage: {TextureUsage.sampled, TextureUsage.copyDestination},
      ),
    );
    await resources.writeTexture(
      texture,
      Uint8List.fromList([
        255,
        0,
        0,
        255,
        255,
        0,
        0,
        255,
        255,
        0,
        0,
        255,
        255,
        0,
        0,
        255,
      ]),
    );
    final bindings = ShaderBindings([
      TextureBinding.sampled(0, texture, group: 3),
      SamplerBinding(1, group: 3),
    ]);
    Future<MeshShaderProgram> compile(String code) => shaders.compileMesh(
      ShaderSource.wgsl(code, label: 'textured mesh'),
      bindings: bindings,
      vertexLayout: MeshVertexLayout.positionNormalUv,
    );
    final program = await compile(textureMesh);
    final second = await compile(textureMesh);
    expect((await backend.graphStats()).liveMeshShaders, 2);
    expect((await backend.graphStats()).meshPipelines, 1);
    await second.close();
    await expectLater(
      compile(textureMesh.replaceFirst('@location(2)', '@location(4)')),
      throwsA(
        isA<GraphException>().having(
          (e) => e.code,
          'code',
          GraphErrorCode.pipelineFailed,
        ),
      ),
    );
    expect((await backend.graphStats()).liveMeshShaders, 1);
    await expectLater(
      shaders.compileMesh(
        ShaderSource.wgsl('''
struct Oversized { values: array<vec4<f32>, 64> };
@group(0) @binding(0) var<uniform> engine: Oversized;
@vertex fn vertex(@location(0) p: vec3<f32>) -> @builtin(position) vec4<f32> {
  return vec4(p, 1.) + engine.values[63];
}
@fragment fn fragment() -> @location(0) vec4<f32> { return vec4(1.); }
'''),
      ),
      throwsA(
        isA<GraphException>().having(
          (e) => e.code,
          'code',
          GraphErrorCode.pipelineFailed,
        ),
      ),
    );

    final material = ShaderMaterial(program, side: MaterialSide.front);
    final mesh = Mesh(PlaneGeometry(width: 2, height: 2), material);
    scene.add(mesh);
    expect(pixel(await draw()), [255, 0, 0, 255]);
    final alternate = await compile(
      textureMesh.replaceFirst(
        'textureSample(source, sourceSampler, input.uv)',
        'textureSample(source, sourceSampler, input.uv).bgra',
      ),
    );
    mesh.material = material.copyWith(program: alternate);
    expect(pixel(await draw()), [0, 0, 255, 255]);
    mesh.material = material;
    expect(pixel(await draw()), [255, 0, 0, 255]);
    await alternate.close();
    mesh.scale = const Vec3(-1, 1, 1);
    expect(pixel(await draw()), [255, 0, 0, 255]);
    mesh.material = material.copyWith(side: MaterialSide.back);
    expect(pixel(await draw()), [0, 0, 255, 255]);
    mesh.material = material.copyWith(
      alphaMode: MaterialAlphaMode.mask,
      opacity: .25,
    );
    expect(pixel(await draw()), [0, 0, 255, 255]);
    mesh.material = material.copyWith(
      alphaMode: MaterialAlphaMode.blend,
      opacity: .5,
    );
    final blend = pixel(await draw());
    expect(blend[0], closeTo(188, 2));
    expect(blend[1], 0);
    expect(blend[2], closeTo(188, 2));
    mesh.material = material;
    final near =
        Mesh(
            PlaneGeometry(width: 2, height: 2),
            UnlitMaterial(color: const Color3(0, 1, 0)),
          )
          ..position = const Vec3(0, 0, .5)
          ..renderOrder = -1;
    scene.add(near);
    expect(pixel(await draw()), [0, 255, 0, 255]);
    mesh.material = material.copyWith(depthTest: false);
    expect(pixel(await draw()), [255, 0, 0, 255]);
    scene.remove(near);
    mesh.material = material.copyWith(depthWrite: DepthWrite.disabled);
    final far =
        Mesh(
            PlaneGeometry(width: 2, height: 2),
            UnlitMaterial(color: const Color3(0, 1, 0)),
          )
          ..position = const Vec3(0, 0, -.5)
          ..renderOrder = 1;
    scene.add(far);
    expect(pixel(await draw()), [0, 255, 0, 255]);
    mesh.material = material;
    expect(pixel(await draw()), [255, 0, 0, 255]);
    scene.remove(far);

    effect = await createFrameEffect(backend, 17, 13);
    expect(pixel(await draw(graph: effect)), [255, 0, 255, 255]);
    await resources.close();
    expect(pixel(await draw(graph: effect)), [255, 0, 255, 255]);
    await program.close();
    mesh.material = UnlitMaterial(color: const Color3(1, 0, 0));
    expect(pixel(await draw()), [255, 0, 0, 255]);
    expect((await backend.graphStats()).liveMeshShaders, 0);
    expect((await backend.graphStats()).meshPipelines, 0);
    scene.remove(mesh);
    await draw();
  } finally {
    await effect?.close();
    await shaders.close();
    await resources.close();
  }
  expect((await backend.resourceStats()).residentBytes, 0);
  expect((await backend.shaderStats()).livePrograms, 0);
}

Future<void> verifyMeshAttachmentAlias(NativeGpuBackend backend) async {
  final resources = backend.createResourceScope();
  final shaders = backend.createShaderCompiler();
  final graphs = backend.createGraphCompiler();
  try {
    Future<GpuResource<Texture>> texture() => resources.createTexture(
      TextureDescriptor(
        width: 17,
        height: 13,
        usage: {TextureUsage.sampled, TextureUsage.renderAttachment},
      ),
    );
    final sceneColor = await texture(), output = await texture();
    final pass = await shaders.compile(ShaderSource.wgsl(frameEffect));
    final graph = await graphs.compile(
      GraphDescription(
        sceneColor: sceneColor,
        output: output,
        passes: [
          RenderPassDescriptor(
            name: 'invert',
            program: pass,
            fragmentEntryPoint: 'invert',
            color: ColorAttachment(output),
            reads: [sceneColor],
            writes: [output],
            bindings: ShaderBindings([TextureBinding.sampled(0, sceneColor)]),
          ),
        ],
      ),
    );
    final program = await shaders.compileMesh(
      ShaderSource.wgsl(textureMesh),
      vertexLayout: MeshVertexLayout.positionNormalUv,
      bindings: ShaderBindings([
        TextureBinding.sampled(0, sceneColor, group: 3),
        SamplerBinding(1, group: 3),
      ]),
    );
    final scene = Scene()..add(Mesh(PlaneGeometry(), ShaderMaterial(program)));
    await expectLater(
      backend.render(
        FrameSubmission.capture(
          scene: scene,
          camera: PerspectiveCamera(),
          size: PhysicalSize(17, 13),
          graph: graph,
        ),
      ),
      throwsA(isA<SceneException>()),
    );
    scene.remove(scene.children.single);
    final frame = await backend.render(
      FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(17, 13),
        graph: graph,
      ),
    );
    expect(frame, isA<ReadbackOutput>());
  } finally {
    await graphs.close();
    await shaders.close();
    await resources.close();
  }
}
