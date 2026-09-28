import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

Future<void> verifySceneAlpha({NativeGpuBackend? providedBackend}) async {
  final backend = providedBackend ?? await NativeBackend.create();
  final scene = Scene();
  final camera = PerspectiveCamera();
  final resources = backend.createResourceScope();
  final shaders = backend.createShaderCompiler();
  final graphs = backend.createGraphCompiler();
  CompiledGraph? graph;
  Future<ReadbackOutput> render({int size = 17}) async =>
      await backend.render(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(size, size),
              graph: graph,
            ),
          )
          as ReadbackOutput;
  void pixel(ReadbackOutput frame, List<int> expected) {
    final size = frame.image.size.width;
    final offset = ((size ~/ 2) * size + size ~/ 2) * 4;
    final actual = frame.image.pixels.sublist(offset, offset + 4);
    for (var i = 0; i < 4; i++) {
      expect(
        actual[i],
        closeTo(expected[i], 2),
        reason: '$actual vs $expected',
      );
    }
    expect(frame.image.alphaMode, AlphaMode.straight);
  }

  UnlitMaterial glass(Color3 color) => UnlitMaterial(
    color: color,
    alphaMode: MaterialAlphaMode.blend,
    opacity: .5,
  );
  try {
    pixel(await render(), [0, 0, 0, 0]);
    scene.background = const Color3(.25, .5, .75);
    scene.backgroundOpacity = .5;
    pixel(await render(), [137, 188, 225, 128]);
    scene.background = null;
    final back = Mesh(
      PlaneGeometry(width: 4, height: 4),
      glass(const Color3(0, 1, 0)),
    );
    final front = Mesh(
      PlaneGeometry(width: 4, height: 4),
      glass(const Color3(1, 0, 0)),
    )..position = const Vec3(0, 0, 1);
    scene.add(front);
    final one = await render();
    pixel(one, [255, 0, 0, 128]);
    expect(one.stats.drawCalls, 2);
    expect(one.stats.triangles, 3);
    scene.add(back);
    pixel(await render(), [213, 156, 0, 191]);
    pixel(await render(size: 23), [213, 156, 0, 191]);
    scene.background = const Color3(0, 0, 0);
    scene.backgroundOpacity = 1;
    pixel(await render(), [188, 137, 0, 255]);
    scene.background = null;
    scene.remove(back);
    Future<GpuResource<Texture>> texture() => resources.createTexture(
      TextureDescriptor(
        width: 17,
        height: 17,
        usage: {TextureUsage.renderAttachment, TextureUsage.sampled},
      ),
    );
    final input = await texture(), output = await texture();
    final shader = await shaders.compile(
      ShaderSource.wgsl('''
@group(0) @binding(0) var source: texture_2d<f32>;
@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  let positions = array<vec2<f32>, 3>(vec2(-1., -1.), vec2(3., -1.), vec2(-1., 3.));
  return vec4<f32>(positions[i], 0., 1.);
}
@fragment fn fragment(@builtin(position) p: vec4<f32>) -> @location(0) vec4<f32> {
  let color = textureLoad(source, vec2<i32>(p.xy), 0);
  return vec4(vec3(1.) - color.rgb, color.a * .5);
}
'''),
    );
    graph = await graphs.compile(
      GraphDescription(
        sceneColor: input,
        output: output,
        passes: [
          RenderPassDescriptor(
            name: 'invert and fade',
            program: shader,
            color: ColorAttachment(output),
            bindings: ShaderBindings([TextureBinding.sampled(0, input)]),
            reads: [input],
            writes: [output],
          ),
        ],
      ),
    );
    final effected = await render();
    pixel(effected, [0, 255, 255, 64]);
    expect(effected.stats.drawCalls, 4);
    scene.remove(front);
    // Effects may contain RGB at alpha zero; capture keeps straight shader output.
    pixel(await render(), [255, 255, 255, 0]);
  } finally {
    await graphs.close();
    await shaders.close();
    await resources.close();
    await backend.close();
  }
}
