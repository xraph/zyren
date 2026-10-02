import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'procedural render passes distinguish replacement, alpha and additive pipelines',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      try {
        final target = await scope.resources.createTexture(
          TextureDescriptor(
            width: 4,
            height: 4,
            format: TextureFormat.rgba8Unorm,
            usage: {TextureUsage.renderAttachment, TextureUsage.copySource},
          ),
        );
        final program = await scope.shaders.compile(
          ShaderSource.wgsl('''
@vertex fn vertex(@builtin(vertex_index) i:u32)->@builtin(position) vec4<f32>{
 let uv=vec2<f32>(f32((i<<1u)&2u),f32(i&2u));return vec4<f32>(uv*2.-1.,0.,1.);
}
@fragment fn fragment()->@location(0) vec4<f32>{return vec4<f32>(.2,.1,.05,.5);}
'''),
        );
        for (final (blend, expected) in [
          (RenderBlend.additive, [102, 51, 26, 255]),
          (RenderBlend.premultipliedAlpha, [77, 38, 19, 191]),
          (RenderBlend.replace, [51, 26, 13, 128]),
          (RenderBlend.additive, [102, 51, 26, 255]),
        ]) {
          final graph = await scope.graphs.compile(
            GraphDescription(
              passes: [
                RenderPassDescriptor(
                  name: 'overlap',
                  program: program,
                  color: ColorAttachment(
                    target,
                    clearColor: const ClearColor(0, 0, 0, 0),
                  ),
                  blend: blend,
                  vertexCount: 3,
                  instanceCount: 2,
                  writes: [target],
                ),
              ],
            ),
          );
          await graph.execute();
          final data = await scope.resources.readTexture(target);
          for (var i = 0; i < data.length; i++) {
            expect(
              data[i],
              closeTo(expected[i % 4], 1),
              reason: '$blend channel${i % 4}',
            );
          }
        }
      } finally {
        await scope.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );
}
