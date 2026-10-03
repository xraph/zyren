import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test('native filtered volumes honor independent W wrap modes', () async {
    final backend = await NativeBackend.create();
    final scope = GpuScope.fromBackend(backend);
    try {
      final volume = await scope.resources.createTexture(
        TextureDescriptor(
          width: 2,
          height: 2,
          depth: 2,
          dimension: TextureDimension.d3,
          format: TextureFormat.rgba8Unorm,
          usage: {TextureUsage.sampled, TextureUsage.copyDestination},
        ),
      );
      final pixels = Uint8List(32);
      for (var i = 0; i < 8; i++) {
        pixels[i * 4] = i < 4 ? 0 : 255;
        pixels[i * 4 + 3] = 255;
      }
      await scope.resources.writeTexture(volume, pixels);
      final output = await scope.resources.createBuffer(
        BufferDescriptor(
          size: 16,
          usage: {BufferUsage.storage, BufferUsage.copySource},
        ),
      );
      final program = await scope.shaders.compile(
        ShaderSource.wgsl('''
@group(0) @binding(0) var image:texture_3d<f32>;
@group(0) @binding(1) var volumeSampler:sampler;
@group(0) @binding(2) var<storage,read_write> result:array<f32>;
@compute @workgroup_size(1) fn main(){
 result[0]=textureSampleLevel(image,volumeSampler,vec3<f32>(.5,.5,0.),0.).r;
 result[1]=textureSampleLevel(image,volumeSampler,vec3<f32>(.5,.5,1.),0.).r;
}
'''),
      );
      for (final mode in TextureWrap.values) {
        final graph = await scope.graphs.compile(
          GraphDescription(
            inputs: [volume, output],
            passes: [
              ComputePassDescriptor(
                name: 'sample volume',
                program: program,
                bindings: ShaderBindings([
                  TextureBinding.sampled(0, volume),
                  SamplerBinding(1, sampler: SamplerDescriptor(wrapW: mode)),
                  BufferBinding.storageReadWrite(2, output),
                ]),
                reads: [volume, output],
                writes: [output],
                workgroups: const Workgroups(1, 1),
              ),
            ],
          ),
        );
        await graph.execute();
        final values = ByteData.sublistView(
          await scope.resources.readBuffer(output),
        );
        expect(
          values.getFloat32(0, Endian.little),
          closeTo(mode == TextureWrap.repeat ? .5 : 0, 1e-6),
        );
        expect(
          values.getFloat32(4, Endian.little),
          closeTo(mode == TextureWrap.repeat ? .5 : 1, 1e-6),
        );
      }
    } finally {
      await scope.close();
      expect((await backend.resourceStats()).residentBytes, 0);
      await backend.close();
    }
  });
}
