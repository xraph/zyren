import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/src/clouds/noise_wgsl.dart';
import 'package:zyren_geospatial/src/clouds/noise_hash.dart';

void main() {
  test(
    'native periodic noise agrees on opposite sides of a repeated cell',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      try {
        final hashes = cloudNoiseHashes();
        final hash = await owner.resources.createBuffer(
          BufferDescriptor(
            size: hashes.lengthInBytes,
            usage: {BufferUsage.storage, BufferUsage.copyDestination},
          ),
        );
        await owner.resources.writeBuffer(hash, hashes);
        final output = await owner.resources.createBuffer(
          BufferDescriptor(
            size: 16 * 4,
            usage: {BufferUsage.storage, BufferUsage.copySource},
          ),
        );
        final program = await owner.shaders.compile(
          ShaderSource.wgsl('''
$cloudNoiseWgsl
@group(0) @binding(0) var<storage,read_write> errors:array<f32>;
fn value(kind:u32,p:vec3<f32>)->vec4<f32>{
 if(kind==0u){return weather(p);}if(kind==1u){return vec4<f32>(shape(p));}
 if(kind==2u){return vec4<f32>(detail(p));}return turbulence(p);
}
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id:vec3<u32>){
 let p=vec3<f32>(.1875,.4375,.8125);let base=value(id.x,p);
 for(var axis=0u;axis<3u;axis++){
   var shift=vec3<f32>(0.);shift[axis]=1.;
   let delta=abs(value(id.x,p+shift)-base);
   errors[id.x*4u+axis]=max(max(delta.x,delta.y),max(delta.z,delta.w));
 }
 errors[id.x*4u+3u]=0.;
}
'''),
        );
        final graph = await owner.graphs.compile(
          GraphDescription(
          inputs: [hash, output],
            passes: [
              ComputePassDescriptor(
                name: 'cloud seams',
                program: program,
                bindings: ShaderBindings([
                  BufferBinding.storageReadWrite(0, output),
                  BufferBinding.storageRead(2, hash),
                ]),
              reads: [hash, output],
                writes: [output],
                workgroups: Workgroups(4),
              ),
            ],
          ),
        );
        await graph.execute();
        final data = ByteData.sublistView(
          await owner.resources.readBuffer(output),
        );
        for (var i = 0; i < 16; i++) {
          expect(
            data.getFloat32(i * 4, Endian.little),
            lessThan(5e-4),
            reason: 'seam $i',
          );
        }
      } finally {
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );
  test(
    'native weather, shape, detail and turbulence match source GLSL',
    () async {
      final fixture = jsonDecode(
        File('test/fixtures/clouds/noise.json').readAsStringSync(),
      );
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final generator = CloudTextureGenerator(owner);
      try {
        for (final kind in CloudTextureKind.values) {
          final texture = await generator.generate(kind, size: 8);
          final reader = owner.createChild();
          final resource = await reader.resources.retain(texture.texture);
          final bytes = await reader.resources.readTexture(resource);
          final float = ByteData.sublistView(bytes);
          var maxError = 0.0;
          for (final sample in (fixture['samples'] as List).where(
            (s) => s['kind'] == kind.index,
          )) {
            final volume =
                kind == CloudTextureKind.shape ||
                kind == CloudTextureKind.detail;
            final pixel =
                ((volume ? sample['z'] as int : 0) * 64 +
                (sample['y'] as int) * 8 +
                (sample['x'] as int));
            for (var c = 0; c < (volume ? 1 : 4); c++) {
              final actual = volume
                  ? float.getFloat32(pixel * 4, Endian.little)
                  : bytes[pixel * 4 + c] / 255;
              final error = (actual - (sample['value'][c] as num)).abs();
              if (error > maxError) maxError = error;
              expect(
                error,
                lessThan(volume ? 1e-5 : .0021),
                reason: '$kind at $pixel channel $c',
              );
              expect(actual.isFinite, isTrue);
              expect(actual, inInclusiveRange(0, 1));
            }
          }
          print('$kind max source float error $maxError');
          final again = await generator.generate(kind, size: 8);
          final secondOwner = owner.createChild();
          final second = await secondOwner.resources.retain(again.texture);
          expect(await secondOwner.resources.readTexture(second), bytes);
          await secondOwner.close();
          await again.close();
          await texture.close();
          await reader.close();
          expect((await backend.resourceStats()).residentBytes, 0);
        }
        final before = (await backend.resourceStats()).residentBytes;
        await expectLater(
          generator.generate(CloudTextureKind.shape, size: 129),
          throwsArgumentError,
        );
        await expectLater(
          generator.generate(CloudTextureKind.weather, size: 513),
          throwsArgumentError,
        );
        await expectLater(
          generator.generate(CloudTextureKind.weather, isCancelled: () => true),
          throwsStateError,
        );
        expect((await backend.resourceStats()).residentBytes, before);
        var checks = 0;
        await expectLater(
          generator.generate(
            CloudTextureKind.shape,
            size: 16,
            isCancelled: () => ++checks > 4,
          ),
          throwsStateError,
        );
        expect((await backend.resourceStats()).residentBytes, before);
        final pending = generator.generate(CloudTextureKind.detail, size: 32);
        await expectLater(
          generator.generate(CloudTextureKind.shape, size: 8),
          throwsStateError,
        );
        await (await pending).close();
        expect((await backend.resourceStats()).residentBytes, before);
        final defaults = <CloudTexture>[];
        final stopwatch = Stopwatch()..start();
        for (final kind in CloudTextureKind.values) {
          defaults.add(await generator.generate(kind));
        }
        expect(defaults.map((v) => v.size), [512, 128, 32, 128]);
        expect((await backend.resourceStats()).residentBytes, 9633792);
        print(
          'Default cloud texture generation: ${stopwatch.elapsedMilliseconds} ms; 9633792 resident bytes',
        );
        for (final texture in defaults) {
          await texture.close();
        }
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: Timeout(Duration(minutes: 3)),
  );
}
