import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'support/png.dart';

/// Native compute and render passes, followed by explicit PNG readback.
Future<void> main(List<String> args) async {
  final path = args.isEmpty ? 'native-graph.png' : args.single;
  final backend = await NativeBackend.create();
  final resources = backend.createResourceScope(label: 'heatmap');
  final shaders = backend.createShaderCompiler(label: 'heatmap');
  final compiler = backend.createGraphCompiler(label: 'heatmap');
  try {
    const size = 256;
    final density = await resources.createTexture(
      TextureDescriptor(
        label: 'density',
        width: size,
        height: size,
        format: TextureFormat.rgba8Unorm,
        usage: {TextureUsage.storage, TextureUsage.sampled},
      ),
    );
    final image = await resources.createTexture(
      TextureDescriptor(
        label: 'display color',
        width: size,
        height: size,
        usage: {TextureUsage.renderAttachment, TextureUsage.copySource},
      ),
    );
    final compute = await shaders.compile(
      ShaderSource.wgsl('''
      @group(0) @binding(0) var output: texture_storage_2d<rgba8unorm, write>;
      @compute @workgroup_size(8, 8, 1)
      fn main(@builtin(global_invocation_id) id: vec3<u32>) {
        let size = textureDimensions(output);
        if (any(id.xy >= size)) { return; }
        let uv = vec2<f32>(id.xy) / vec2<f32>(size - vec2<u32>(1));
        let rings = 0.5 + 0.5 * sin(length(uv - vec2<f32>(0.5)) * 50.0);
        textureStore(output, vec2<i32>(id.xy), vec4<f32>(uv.x, uv.y, rings * 0.35, 1.));
      }
    ''', label: 'heatmap.wgsl'),
    );
    final render = await shaders.compile(
      ShaderSource.wgsl('''
      @group(0) @binding(0) var density: texture_2d<f32>;
      @group(0) @binding(1) var textureSampler: sampler;
      @vertex fn vertex(@builtin(vertex_index) index: u32) -> @builtin(position) vec4<f32> {
        let vertices = array<vec2<f32>, 6>(vec2(-1., -1.), vec2(1., -1.), vec2(-1., 1.),
          vec2(-1., 1.), vec2(1., -1.), vec2(1., 1.));
        return vec4<f32>(vertices[index], 0., 1.);
      }
      @fragment fn fragment(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
        return textureSample(density, textureSampler, pixel.xy / vec2<f32>(textureDimensions(density)));
      }
    ''', label: 'display.wgsl'),
    );
    final graph = RenderGraph()
      ..addCompute(
        ComputePassDescriptor(
          name: 'heatmap.update',
          program: compute,
          workgroups: const Workgroups(size ~/ 8, size ~/ 8),
          bindings: ShaderBindings([TextureBinding.storage(0, density)]),
          writes: [density],
        ),
      )
      ..addRender(
        RenderPassDescriptor(
          name: 'heatmap.display',
          program: render,
          vertexCount: 6,
          color: ColorAttachment(image),
          bindings: ShaderBindings([
            TextureBinding.sampled(0, density),
            SamplerBinding(1),
          ]),
          reads: [density],
          writes: [image],
        ),
      );
    final compiled = await compiler.compile(graph.describe(label: 'heatmap'));
    final stats = await compiled.execute();
    final pixels = await resources.readTexture(image);
    File(path).writeAsBytesSync(
      png(ImageData(pixels: pixels, size: PhysicalSize(size, size))),
    );
    print(
      'Saved $path from ${stats.dispatches} native compute dispatch and ${stats.drawCalls} draw.',
    );
    await compiler.close();
    await resources.close();
    await shaders.close();
    print(
      'After cleanup: ${(await backend.resourceStats()).residentBytes} resource bytes, '
      '${(await backend.graphStats()).cachedPipelines} cached pipelines.',
    );
  } finally {
    await backend.close();
  }
}
