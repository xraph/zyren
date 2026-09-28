import 'dart:convert';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

Uint8List hdrFixture() => Uint8List.fromList([
  ...ascii.encode('#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 2\n'),
  8, 64, 128, 131, // .25, 2, 4
  16, 128, 128, 131, // .5, 4, 4
  24, 64, 128, 131, // .75, 2, 4
  32, 128, 128, 131, // 1, 4, 4
]);

Future<void> verifyHdrAsset(NativeGpuBackend backend) async {
  final image = await const NativeHdrImageDecoder().decode(hdrFixture());
  expect(image.pixels, [.25, 2, 4, 1, .5, 4, 4, 1, .75, 2, 4, 1, 1, 4, 4, 1]);
  final scope = backend.createResourceScope();
  final shaders = backend.createShaderCompiler();
  final graphs = backend.createGraphCompiler();
  final before = await backend.resourceStats();
  try {
    final source = await scope.createTexture(
      TextureDescriptor(
        width: 2,
        height: 2,
        mipLevels: 2,
        format: TextureFormat.rgba16Float,
        usage: {
          TextureUsage.sampled,
          TextureUsage.copyDestination,
          TextureUsage.copySource,
          TextureUsage.renderAttachment,
        },
      ),
    );
    await scope.writeTexture(source, image.toRgba16Float());
    expect(await scope.readTexture(source), image.toRgba16Float());
    await scope.generateMipmaps(source);
    // Linear average (.625, 3, 4, 1), independent binary16 oracle.
    expect(await scope.readTexture(source, mipLevel: 1), [
      0,
      0x39,
      0,
      0x42,
      0,
      0x44,
      0,
      0x3c,
    ]);
    final output = await scope.createTexture(
      TextureDescriptor(
        width: 1,
        height: 1,
        format: TextureFormat.rgba16Float,
        usage: {TextureUsage.storage, TextureUsage.copySource},
      ),
    );
    final program = await shaders.compile(
      ShaderSource.wgsl('''
@group(0) @binding(0) var environment: texture_2d<f32>;
@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
@compute @workgroup_size(1) fn main() {
  textureStore(output, vec2(0), textureLoad(environment, vec2(0), 1) * vec4(2., 2., 2., 1.));
}
'''),
    );
    final graph = await graphs.compile(
      GraphDescription(
        inputs: [source],
        passes: [
          ComputePassDescriptor(
            name: 'HDR asset lighting values',
            program: program,
            workgroups: const Workgroups(1),
            reads: [source],
            writes: [output],
            bindings: ShaderBindings([
              TextureBinding.sampled(0, source, mipLevels: 2),
              TextureBinding.storage(1, output),
            ]),
          ),
        ],
      ),
    );
    await graph.execute();
    expect(await scope.readTexture(output), [
      0,
      0x3d,
      0,
      0x46,
      0,
      0x48,
      0,
      0x3c,
    ]);
  } finally {
    await graphs.close();
    await shaders.close();
    await scope.close();
  }
  expect((await backend.resourceStats()).residentBytes, before.residentBytes);
}
