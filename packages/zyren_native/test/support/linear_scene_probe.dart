import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

/// Reads scene radiance before exposure, tone mapping or sRGB conversion.
class LinearSceneProbe {
  final NativeGpuBackend backend;
  final ResourceScope resources;
  final ShaderCompiler shaders;
  final GraphCompiler compiler;
  final GpuResource<GpuTexture> input;
  final CompiledGraph graph;
  LinearSceneProbe._(
    this.backend,
    this.resources,
    this.shaders,
    this.compiler,
    this.input,
    this.graph,
  );
  static Future<LinearSceneProbe> create(NativeGpuBackend backend) async {
    final resources = backend.createResourceScope(),
        shaders = backend.createShaderCompiler(),
        compiler = backend.createGraphCompiler();
    try {
      Future<GpuResource<GpuTexture>> texture() => resources.createTexture(
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
      final input = await texture(), output = await texture();
      final program = await shaders.compile(
        ShaderSource.wgsl('''
@group(0) @binding(0) var source: texture_2d<f32>;
@vertex fn vertex(@builtin(vertex_index) i:u32) -> @builtin(position) vec4<f32> {
  let p=array<vec2<f32>,3>(vec2(-1.,-1.),vec2(3.,-1.),vec2(-1.,3.));
  return vec4(p[i],0.,1.);
}
@fragment fn fragment(@builtin(position) p:vec4<f32>) -> @location(0) vec4<f32> {
  return textureLoad(source,vec2<i32>(p.xy),0);
}
'''),
      );
      final graph = await compiler.compile(
        GraphDescription(
          sceneColor: input,
          output: output,
          passes: [
            RenderPassDescriptor(
              name: 'linear reference',
              program: program,
              color: ColorAttachment(output),
              reads: [input],
              writes: [output],
              bindings: ShaderBindings([TextureBinding.sampled(0, input)]),
            ),
          ],
        ),
      );
      return LinearSceneProbe._(
        backend,
        resources,
        shaders,
        compiler,
        input,
        graph,
      );
    } catch (_) {
      await compiler.close();
      await shaders.close();
      await resources.close();
      rethrow;
    }
  }

  Future<List<double>> draw(
    Scene scene,
    PerspectiveCamera camera, {
    Environment? environment,
  }) async {
    await backend.render(
      FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(31, 31),
        graph: graph,
        environment: environment,
        colorPipeline: ColorPipeline(toneMapping: ToneMapping.linear),
      ),
    );
    final bytes = ByteData.sublistView(await resources.readTexture(input));
    return [
      for (var i = 0; i < 4; i++)
        _half(bytes.getUint16((15 * 31 + 15) * 8 + i * 2, Endian.little)),
    ];
  }

  Future<void> close() async {
    await backend.render(
      FrameSubmission.capture(
        scene: Scene(),
        camera: PerspectiveCamera(),
        size: PhysicalSize(1, 1),
      ),
    );
    await compiler.close();
    await shaders.close();
    await resources.close();
  }
}

double _half(int bits) {
  final exponent = (bits >> 10) & 31, mantissa = bits & 1023;
  expect(bits >> 15, 0, reason: 'nonnegative scene radiance');
  expect(exponent, lessThan(31), reason: 'finite scene radiance');
  return exponent == 0
      ? mantissa * math.pow(2, -24).toDouble()
      : (1 + mantissa / 1024) * math.pow(2, exponent - 15);
}
