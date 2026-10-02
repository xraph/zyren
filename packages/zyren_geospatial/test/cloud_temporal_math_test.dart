import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/src/clouds/temporal_wgsl.dart';

void main() {
  test(
    'native variance clipping matches original five and nine sample GLSL',
    () async {
      final samples =
          jsonDecode(
                File('test/fixtures/clouds/temporal.json').readAsStringSync(),
              )['samples']
              as List;
      final values = Float32List.fromList([
        for (final s in samples) ...[
          for (final p in s['neighbors'] as List)
            ...(p as List).cast<num>().map((v) => v.toDouble()),
          ...(s['history'] as List).cast<num>().map((v) => v.toDouble()),
          (s['gamma'] as num).toDouble(),
          (s['count'] as num).toDouble(),
          0,
          0,
        ],
      ]);
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      try {
        final input = await owner.resources.createBuffer(
          BufferDescriptor(
            size: values.lengthInBytes,
            usage: {BufferUsage.storage, BufferUsage.copyDestination},
          ),
        );
        await owner.resources.writeBuffer(input, values);
        final output = await owner.resources.createBuffer(
          BufferDescriptor(
            size: samples.length * 16,
            usage: {BufferUsage.storage, BufferUsage.copySource},
          ),
        );
        final shader = await owner.shaders.compile(
          ShaderSource.wgsl('''
$cloudVarianceWgsl
@group(0) @binding(0) var<storage,read> data:array<vec4<f32>>;
@group(0) @binding(1) var<storage,read_write> out:array<vec4<f32>>;
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id:vec3<u32>){
 let start=id.x*11u;let settings=data[start+10u];var first=data[start+4u];var second=first*first;
 let offsets=array<u32,8>(0u,6u,2u,8u,5u,1u,7u,3u);
 for(var i=0u;i<8u;i++){if(settings.y==9.||i>=4u){let v=data[start+offsets[i]];first+=v;second+=v*v;}}
 out[id.x]=cloudVariance(data[start+9u],first,second,settings.y,settings.x);
}
'''),
        );
        final graph = await owner.graphs.compile(
          GraphDescription(
            inputs: [input, output],
            passes: [
              ComputePassDescriptor(
                name: 'original variance',
                program: shader,
                bindings: ShaderBindings([
                  BufferBinding.storageRead(0, input),
                  BufferBinding.storageReadWrite(1, output),
                ]),
                reads: [input, output],
                writes: [output],
                workgroups: Workgroups(samples.length),
              ),
            ],
          ),
        );
        await graph.execute();
        final result = ByteData.sublistView(
          await owner.resources.readBuffer(output),
        );
        for (var i = 0; i < samples.length; i++) {
          for (var c = 0; c < 4; c++) {
            expect(
              result.getFloat32((i * 4 + c) * 4, Endian.little),
              closeTo(samples[i]['expected'][c], .000003),
              reason: 'case $i channel $c',
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
