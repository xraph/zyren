import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial/src/clouds/media_wgsl.dart';
import 'package:zyren_geospatial/src/clouds/media_uniforms.dart';
import 'package:zyren_geospatial/src/clouds/sampling_wgsl.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'native cloud texture filtering repeats volumes and respects weather mip levels',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      try {
        final weather = await owner.resources.createTexture(
          TextureDescriptor(
            width: 2,
            height: 2,
            mipLevels: 2,
            format: TextureFormat.rgba32Float,
          ),
        );
        await owner.resources.writeTexture(
          weather,
          Float32List.fromList([
            1,
            0,
            0,
            1,
            0,
            1,
            0,
            1,
            0,
            0,
            1,
            1,
            1,
            1,
            1,
            1,
          ]).buffer.asUint8List(),
        );
        await owner.resources.writeTexture(
          weather,
          Float32List.fromList([.25, .5, .75, 1]).buffer.asUint8List(),
          mipLevel: 1,
        );
        final shape = await owner.resources.createTexture(
          TextureDescriptor(
            width: 2,
            height: 2,
            depth: 2,
            dimension: TextureDimension.d3,
            format: TextureFormat.r32Float,
          ),
        );
        await owner.resources.writeTexture(
          shape,
          Float32List.fromList([
            0,
            .1,
            .2,
            .3,
            .4,
            .5,
            .6,
            .7,
          ]).buffer.asUint8List(),
        );
        final maps = CloudTextures(
          weather: weather,
          shape: shape,
          detail: shape,
          turbulence: weather,
        );
        expect(
          () => CloudTextures(
            weather: shape,
            shape: shape,
            detail: shape,
            turbulence: weather,
          ),
          throwsArgumentError,
        );
        final data = cloudMediaUniforms(CloudParameters(), CloudAppearance());
        final uniform = await owner.resources.createBuffer(
          BufferDescriptor(
            size: data.lengthInBytes,
            usage: {BufferUsage.uniform, BufferUsage.copyDestination},
          ),
        );
        await owner.resources.writeBuffer(uniform, data);
        final output = await owner.resources.createBuffer(
          BufferDescriptor(
            size: 8 * 16,
            usage: {BufferUsage.storage, BufferUsage.copySource},
          ),
        );
        final program = await owner.shaders.compile(
          ShaderSource.wgsl('''
${cloudMediaMathWgsl(CloudQuality.forPreset(CloudQualityPreset.high))}
$cloudSamplingWgsl
@group(0) @binding(0) var<storage,read_write> output:array<vec4<f32>>;
@compute @workgroup_size(1) fn main(){
 output[0]=sample_cloudShapeMap(vec3<f32>(.25),0.);
 output[1]=sample_cloudShapeMap(vec3<f32>(.75),0.);
 output[2]=sample_cloudShapeMap(vec3<f32>(.5),0.);
 output[3]=sample_cloudShapeMap(vec3<f32>(-.25,.75,1.25),0.);
 output[4]=sample_cloudWeatherMap(vec2<f32>(.5),0.);
 output[5]=sample_cloudWeatherMap(vec2<f32>(-.25,.25),0.);
 output[6]=sample_cloudWeatherMap(vec2<f32>(.25),1.);
 output[7]=sample_cloudWeatherMap(vec2<f32>(.25),.5);
}
'''),
        );
        final resources = <GpuResource>[uniform, weather, shape, output];
        final graph = await owner.graphs.compile(
          GraphDescription(
            inputs: resources,
            passes: [
              ComputePassDescriptor(
                name: 'cloud filtering',
                program: program,
                bindings: ShaderBindings([
                  BufferBinding.uniform(0, uniform, group: 2),
                  for (var i = 0; i < 4; i++)
                    TextureBinding.sampled(
                      i + 1,
                      maps.resources[i],
                      group: 2,
                      mipLevels:
                          (maps.resources[i].descriptor as TextureDescriptor)
                              .mipLevels,
                    ),
                  BufferBinding.storageReadWrite(0, output),
                ]),
                reads: resources,
                writes: [output],
                workgroups: const Workgroups(1),
              ),
            ],
          ),
        );
        await graph.execute();
        final bytes = ByteData.sublistView(
          await owner.resources.readBuffer(output),
        );
        for (var i = 0; i < 4; i++) {
          expect(
            bytes.getFloat32(i * 16, Endian.little),
            closeTo([0, .7, .35, .3][i], 1e-6),
          );
        }
        const expected = [
          [.5, .5, .5, 1],
          [0, 1, 0, 1],
          [.25, .5, .75, 1],
          [.625, .25, .375, 1],
        ];
        for (var i = 0; i < 4; i++) {
          for (var c = 0; c < 4; c++) {
            expect(
              bytes.getFloat32((i + 4) * 16 + c * 4, Endian.little),
              closeTo(expected[i][c], 1e-6),
            );
          }
        }
      } finally {
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );
}
