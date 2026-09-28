import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'float volume upload and mip readback preserve all depth slices',
    () async {
      final backend = await NativeBackend.create();
      final scope = backend.createResourceScope();
      try {
        final texture = await scope.createTexture(
          TextureDescriptor(
            width: 5,
            height: 3,
            depth: 3,
            mipLevels: 3,
            dimension: TextureDimension.d3,
            format: TextureFormat.r32Float,
            usage: {TextureUsage.copyDestination, TextureUsage.copySource},
          ),
        );
        for (var level = 0; level < 3; level++) {
          final length = (texture.descriptor as TextureDescriptor)
              .mipByteLength(level);
          final values = Float32List.fromList(
            List.generate(length ~/ 4, (i) => i * .25 - 3.5),
          );
          await scope.writeTexture(texture, values, mipLevel: level);
          expect(
            await scope.readTexture(texture, mipLevel: level),
            values.buffer.asUint8List(),
          );
        }
        await scope.close();
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'compute fills float volume and render samples HDR values without clamp',
    () async {
      final backend = await NativeBackend.create();
      final scope = backend.createResourceScope();
      final shaders = backend.createShaderCompiler();
      final compiler = backend.createGraphCompiler();
      try {
        final volume = await scope.createTexture(
          TextureDescriptor(
            width: 5,
            height: 3,
            depth: 4,
            dimension: TextureDimension.d3,
            format: TextureFormat.rgba16Float,
            usage: {TextureUsage.storage, TextureUsage.sampled},
          ),
        );
        final target = await scope.createTexture(
          TextureDescriptor(
            width: 5,
            height: 3,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.renderAttachment, TextureUsage.copySource},
          ),
        );
        final compute = await shaders.compile(
          ShaderSource.wgsl('''
@group(0) @binding(0) var volume: texture_storage_3d<rgba16float, write>;
@compute @workgroup_size(1, 1, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  textureStore(volume, vec3<i32>(id), vec4<f32>(f32(id.x)+4., f32(id.y)*0.125, -f32(id.z)*0.5, 1.));
}
'''),
        );
        final sample = await shaders.compile(
          ShaderSource.wgsl('''
@group(0) @binding(0) var volume: texture_3d<f32>;
@group(0) @binding(1) var linearSampler: sampler;
@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  let p = array<vec2<f32>, 3>(vec2(-1., -1.), vec2(3., -1.), vec2(-1., 3.));
  return vec4(p[i], 0., 1.);
}
@fragment fn fragment(@builtin(position) p: vec4<f32>) -> @location(0) vec4<f32> {
  return textureSample(volume, linearSampler, vec3(p.xy/vec2(5.,3.),0.875));
}
'''),
        );
        final graph = await compiler.compile(
          GraphDescription(
            passes: [
              ComputePassDescriptor(
                name: 'volume',
                program: compute,
                workgroups: const Workgroups(5, 3, 4),
                writes: [volume],
                bindings: ShaderBindings([TextureBinding.storage(0, volume)]),
              ),
              RenderPassDescriptor(
                name: 'sample',
                program: sample,
                vertexCount: 3,
                color: ColorAttachment(target),
                reads: [volume],
                writes: [target],
                bindings: ShaderBindings([
                  TextureBinding.sampled(0, volume),
                  SamplerBinding(1),
                ]),
              ),
            ],
          ),
        );
        final stats = await graph.execute();
        expect(stats.dispatches, 1);
        expect(stats.drawCalls, 1);
        for (final descriptor in [
          TextureDescriptor(
            width: 5,
            height: 3,
            depth: 4,
            dimension: TextureDimension.d3,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.storage},
          ),
          TextureDescriptor(
            width: 5,
            height: 3,
            format: TextureFormat.rgba16Float,
            usage: {TextureUsage.storage},
          ),
        ]) {
          final incompatible = await scope.createTexture(descriptor);
          await expectLater(
            compiler.compile(
              GraphDescription(
                passes: [
                  ComputePassDescriptor(
                    name: 'incompatible',
                    program: compute,
                    workgroups: const Workgroups(1),
                    writes: [incompatible],
                    bindings: ShaderBindings([
                      TextureBinding.storage(0, incompatible),
                    ]),
                  ),
                ],
              ),
            ),
            throwsA(
              isA<GraphException>().having(
                (e) => e.code,
                'code',
                GraphErrorCode.pipelineFailed,
              ),
            ),
          );
          expect(compiler.active, same(graph));
          expect((await backend.graphStats()).cachedPipelines, 2);
        }
        await graph.execute();
        final bytes = ByteData.sublistView(await scope.readTexture(target));
        for (var y = 0; y < 3; y++) {
          for (var x = 0; x < 5; x++) {
            final offset = (y * 5 + x) * 16;
            final expected = [x + 4.0, y * .125, -1.5, 1.0];
            for (var c = 0; c < 4; c++) {
              expect(
                bytes.getFloat32(offset + c * 4, Endian.little),
                closeTo(expected[c], 1e-5),
              );
            }
          }
        }
        await compiler.close();
        await shaders.close();
        await scope.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        expect((await backend.graphStats()).liveGraphs, 0);
        expect((await backend.shaderStats()).livePrograms, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
