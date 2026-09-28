import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'support/png.dart';

/// Draws meshes, rotates their color channels in compute, then applies a vignette.
Future<void> main(List<String> args) async {
  final path = args.isEmpty ? 'native-frame-graph.png' : args.single;
  final backend = await NativeBackend.create();
  final resources = backend.createResourceScope();
  final shaders = backend.createShaderCompiler();
  final compiler = backend.createGraphCompiler();
  try {
    const width = 512, height = 320;
    final sceneColor = await resources.createTexture(
      TextureDescriptor(
        width: width,
        height: height,
        usage: {TextureUsage.renderAttachment, TextureUsage.sampled},
      ),
    );
    final intermediate = await resources.createTexture(
      TextureDescriptor(
        width: width,
        height: height,
        format: TextureFormat.rgba8Unorm,
        usage: {TextureUsage.storage, TextureUsage.sampled},
      ),
    );
    final output = await resources.createTexture(
      TextureDescriptor(
        width: width,
        height: height,
        usage: {TextureUsage.renderAttachment, TextureUsage.sampled},
      ),
    );
    final program = await shaders.compile(
      ShaderSource.wgsl('''
@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var rotated: texture_storage_2d<rgba8unorm, write>;
@compute @workgroup_size(8, 8) fn compute(@builtin(global_invocation_id) id: vec3<u32>) {
  if (any(id.xy >= textureDimensions(rotated))) { return; }
  textureStore(rotated, vec2<i32>(id.xy), vec4(textureLoad(source, vec2<i32>(id.xy), 0).brg, 1.));
}
@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  let positions = array<vec2<f32>, 3>(vec2(-1., -1.), vec2(3., -1.), vec2(-1., 3.));
  return vec4<f32>(positions[i], 0., 1.);
}
@fragment fn fragment(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
  let uv = pixel.xy / vec2<f32>(textureDimensions(source));
  let vignette = 1. - 0.75 * dot(uv - vec2(0.5), uv - vec2(0.5));
  return vec4(textureLoad(source, vec2<i32>(pixel.xy), 0).rgb * vignette, 1.);
}
''', label: 'scene-effects.wgsl'),
    );
    final graph = await compiler.compile(
      GraphDescription(
        sceneColor: sceneColor,
        output: output,
        passes: [
          ComputePassDescriptor(
            name: 'rotate',
            program: program,
            entryPoint: 'compute',
            workgroups: const Workgroups(width ~/ 8, height ~/ 8),
            bindings: ShaderBindings([
              TextureBinding.sampled(0, sceneColor),
              TextureBinding.storage(1, intermediate),
            ]),
            reads: [sceneColor],
            writes: [intermediate],
          ),
          RenderPassDescriptor(
            name: 'vignette',
            program: program,
            color: ColorAttachment(output),
            bindings: ShaderBindings([TextureBinding.sampled(0, intermediate)]),
            reads: [intermediate],
            writes: [output],
          ),
        ],
      ),
    );
    await resources.close();
    await shaders.close();
    final scene = Scene()..background = const Color3(.025, .035, .06);
    for (final (x, color) in [
      (-1.4, const Color3(.85, .06, .04)),
      (0.0, const Color3(.05, .75, .15)),
      (1.4, const Color3(.05, .2, .9)),
    ]) {
      scene.add(
        Mesh(BoxGeometry(), DiffuseMaterial(color: color))
          ..position = Vec3(x, 0, 0),
      );
    }
    final frame =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: PerspectiveCamera(position: const Vec3(4, 3, 7)),
                size: PhysicalSize(width, height),
                graph: graph,
              ),
            )
            as ReadbackOutput;
    File(path).writeAsBytesSync(png(frame.image));
    print(
      'Saved $path: ${frame.stats.drawCalls} draws, ${frame.stats.computeDispatches} compute dispatch.',
    );
    await compiler.close();
  } finally {
    await backend.close();
  }
}
