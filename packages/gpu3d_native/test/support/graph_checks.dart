import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

const _density = '''
@group(0) @binding(0) var output: texture_storage_2d<rgba8unorm, write>;
@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  if (any(id.xy >= textureDimensions(output))) { return; }
  textureStore(output, vec2<i32>(id.xy), vec4<f32>(f32(id.x)/63., f32(id.y)/63., 0.25, 1.));
}
''';
const _sample = '''
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
''';

Future<void> verifyNativeGraph({NativeGpuBackend? providedBackend}) async {
  final backend = providedBackend ?? await NativeBackend.create();
  final scope = backend.createResourceScope();
  final reader = backend.createResourceScope();
  final shaders = backend.createShaderCompiler();
  final compiler = backend.createGraphCompiler(label: 'weather');
  try {
    final texture = await scope.createTexture(
      TextureDescriptor(
        label: 'density',
        width: 64,
        height: 64,
        format: TextureFormat.rgba8Unorm,
        usage: {TextureUsage.storage, TextureUsage.sampled},
      ),
    );
    final target = await scope.createTexture(
      TextureDescriptor(
        label: 'color',
        width: 64,
        height: 64,
        format: TextureFormat.rgba8Unorm,
        usage: {TextureUsage.renderAttachment, TextureUsage.copySource},
      ),
    );
    final output = await reader.retain(target);
    final compute = await shaders.compile(
      ShaderSource.wgsl(_density, label: 'density.wgsl'),
    );
    final fragment = await shaders.compile(
      ShaderSource.wgsl(_sample, label: 'sample.wgsl'),
    );
    ComputePassDescriptor write(ShaderProgram program) => ComputePassDescriptor(
      name: 'density',
      program: program,
      workgroups: const Workgroups(8, 8),
      bindings: ShaderBindings([TextureBinding.storage(0, texture)]),
      writes: [texture],
    );
    RenderPassDescriptor sample({bool invalidLayout = false}) =>
        RenderPassDescriptor(
          name: 'sample',
          program: fragment,
          vertexCount: 6,
          color: ColorAttachment(target),
          reads: [texture],
          writes: [target],
          bindings: ShaderBindings([
            TextureBinding.sampled(0, texture),
            SamplerBinding(
              invalidLayout ? 2 : 1,
              sampler: const SamplerDescriptor(
                minFilter: TextureFilter.nearest,
                magFilter: TextureFilter.nearest,
                mipFilter: TextureFilter.nearest,
              ),
            ),
          ]),
        );
    final red = await shaders.compile(
      ShaderSource.wgsl(
        _density.replaceFirst(
          'f32(id.x)/63., f32(id.y)/63., 0.25, 1.',
          '1., 0., 0., 1.',
        ),
        label: 'red.wgsl',
      ),
    );
    final baseline = await compiler.compile(
      GraphDescription(passes: [sample(), write(red)]),
    );
    await baseline.execute();
    expect(await reader.readTexture(output), [
      for (var i = 0; i < 64 * 64; i++) ...[255, 0, 0, 255],
    ]);
    final graph = await compiler.compile(
      GraphDescription(passes: [sample(), write(compute)]),
    );
    expect(baseline.isClosed, isTrue);
    expect(graph.passNames, ['density', 'sample']);
    expect((await backend.graphStats()).cachedPipelines, 2);
    await expectLater(
      compiler.compile(
        GraphDescription(passes: [write(compute), sample(invalidLayout: true)]),
      ),
      throwsA(
        isA<GraphException>()
            .having((e) => e.code, 'code', GraphErrorCode.pipelineFailed)
            .having((e) => e.passName, 'pass', 'sample'),
      ),
    );
    expect(compiler.active, same(graph));
    expect((await backend.graphStats()).cachedPipelines, 2);
    await scope.close();
    await shaders.close();
    expect((await backend.shaderStats()).livePrograms, 2);
    final result = await graph.execute();
    expect(result.passes, 2);
    expect(result.dispatches, 1);
    expect(result.drawCalls, 1);
    final pixels = await reader.readTexture(output);
    for (final (x, y) in [(0, 0), (63, 0), (0, 63), (63, 63), (31, 31)]) {
      final index = (y * 64 + x) * 4;
      expect(pixels[index], closeTo(x / 63 * 255, 1));
      expect(pixels[index + 1], closeTo(y / 63 * 255, 1));
      expect(pixels[index + 2], closeTo(64, 1));
      expect(pixels[index + 3], 255);
    }
    await compiler.close();
    expect((await backend.graphStats()).liveGraphs, 0);
    expect((await backend.graphStats()).cachedPipelines, 0);
    expect((await backend.shaderStats()).livePrograms, 0);
    expect((await backend.shaderStats()).cachedModules, 0);
    expect((await backend.resourceStats()).residentBytes, 64 * 64 * 4);
    await reader.close();
    expect((await backend.resourceStats()).residentBytes, 0);
  } finally {
    await backend.close();
  }
}

Future<void> verifyNativeGraphBuffers({
  NativeGpuBackend? providedBackend,
}) async {
  final backend = providedBackend ?? await NativeBackend.create();
  final scope = backend.createResourceScope();
  final compiler = backend.createGraphCompiler();
  try {
    final params = await scope.createBuffer(
      BufferDescriptor(
        label: 'parameters',
        size: 512,
        usage: {BufferUsage.uniform, BufferUsage.copyDestination},
      ),
    );
    final values = await scope.createBuffer(
      BufferDescriptor(
        label: 'result',
        size: 16,
        usage: {BufferUsage.storage, BufferUsage.copySource},
      ),
    );
    await scope.writeBuffer(
      params,
      Uint32List.fromList([20, 0, 0, 0]),
      offset: 256,
    );
    final program = await backend.createShaderCompiler().compile(
      ShaderSource.wgsl('''
      struct Parameters { value: vec4<u32> }
      @group(0) @binding(0) var<uniform> params: Parameters;
      @group(0) @binding(1) var<storage, read_write> values: array<u32>;
      @compute @workgroup_size(1) fn main() { values[0] = params.value.x + 7u; }
    '''),
    );
    GraphDescription description({
      bool readOnly = false,
      int uniformSize = 16,
    }) => GraphDescription(
      inputs: [params, values],
      passes: [
        ComputePassDescriptor(
          name: 'transform',
          program: program,
          workgroups: const Workgroups(1),
          bindings: ShaderBindings([
            BufferBinding.uniform(0, params, offset: 256, size: uniformSize),
            if (readOnly)
              BufferBinding.storageRead(1, values)
            else
              BufferBinding.storageReadWrite(1, values),
          ]),
          reads: [params, values],
          writes: readOnly ? [] : [values],
        ),
      ],
    );
    final original = await compiler.compile(description());
    final graph = await compiler.compile(description());
    expect(original.isClosed, isTrue);
    expect((await backend.graphStats()).pipelineCompilations, 1);
    expect((await backend.graphStats()).cacheHits, 1);
    for (final bad in [
      description(readOnly: true),
      description(uniformSize: 4),
    ]) {
      await expectLater(
        compiler.compile(bad),
        throwsA(
          isA<GraphException>().having(
            (e) => e.code,
            'code',
            GraphErrorCode.pipelineFailed,
          ),
        ),
      );
      expect(compiler.active, same(graph));
    }
    await graph.execute();
    expect(
      ByteData.sublistView(
        await scope.readBuffer(values),
      ).getUint32(0, Endian.little),
      27,
    );
    await scope.writeBuffer(
      params,
      Uint32List.fromList([81, 0, 0, 0]),
      offset: 256,
    );
    await graph.execute();
    expect(
      ByteData.sublistView(
        await scope.readBuffer(values),
      ).getUint32(0, Endian.little),
      88,
    );
    final pending = graph.execute();
    await backend.close();
    await pending;
    expect(graph.isClosed, isTrue);
    expect(compiler.isClosed, isTrue);
  } finally {
    await backend.close();
  }
}
