import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'package:zyren_geospatial/src/clouds/media_wgsl.dart';
import 'package:zyren_geospatial/src/clouds/sampling_wgsl.dart';
import 'package:zyren_geospatial/src/clouds/render_wgsl.dart';
import 'cloud_media_test.dart' show referenceParameters;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial/src/clouds/frame.dart';
import 'package:zyren_geospatial/src/clouds/shadow_pass.dart';
import 'package:zyren_native/zyren_native.dart';

Future<CloudTextures> constantCloudTextures(GpuScope scope) async {
  Future<GpuResource<Texture>> image(bool volume, double value) async {
    final texture = await scope.resources.createTexture(
      TextureDescriptor(
        width: 1,
        height: 1,
        depth: 1,
        dimension: volume ? TextureDimension.d3 : TextureDimension.d2,
        format: volume ? TextureFormat.r32Float : TextureFormat.rgba8Unorm,
      ),
    );
    await scope.resources.writeTexture(
      texture,
      volume
          ? Float32List.fromList([value]).buffer.asUint8List()
          : Uint8List.fromList(List.filled(4, (value * 255).round())),
    );
    return texture;
  }

  return CloudTextures(
    weather: await image(false, 1),
    shape: await image(true, 1),
    detail: await image(true, 0),
    turbulence: await image(false, .5),
  );
}

void main() {
  for (final preset in [CloudQualityPreset.low, CloudQualityPreset.medium]) {
    test(
      '${preset.name} cloud radiance and depth match the original primary marcher',
      () async {
        final backend = await NativeBackend.create();
        final owner = GpuScope.fromBackend(backend);
        try {
          final textures = await constantCloudTextures(owner);
          final q = CloudQuality.forPreset(preset);
          final pass = await CloudShadowPass.build(
            owner,
            textures,
            q,
            mapSize: 8,
          );
          final camera = PerspectiveCamera(
            position: const Vec3(0, 0, 6360100),
            target: const Vec3(0, 10000, 6360100),
            up: const Vec3(0, 0, 1),
            near: 1,
            far: 20000,
          );
          await pass.render(
            referenceParameters(),
            CloudAppearance(),
            CloudFrameState(
              camera: camera,
              worldToEcef: Mat4.identity(),
              correctedCamera: camera.position,
              sun: const Vec3(0, 0, 1),
              aspect: 1,
              width: 8,
              height: 8,
              shadowSize: 8,
              cascadeCount: q.shadow.cascadeCount,
            ),
          );
          final fixture = jsonDecode(
            File(
              'test/fixtures/clouds/march${preset == CloudQualityPreset.low ? '' : '_${preset.name}'}.json',
            ).readAsStringSync(),
          );
          final samples = fixture['samples'] as List;
          final values = Float32List.fromList([
            for (final s in samples) ...[
              ...(s['origin'] as List).cast<num>().map((v) => v.toDouble()),
              (s['range'][0] as num).toDouble(),
              ...(s['direction'] as List).cast<num>().map((v) => v.toDouble()),
              (s['range'][1] as num).toDouble(),
              (s['jitter'] as num).toDouble(),
              (s['texels'] as num).toDouble(),
              0,
              0,
            ],
          ]);
          final input = await owner.resources.createBuffer(
            BufferDescriptor(
              size: values.lengthInBytes,
              usage: {BufferUsage.storage, BufferUsage.copyDestination},
            ),
          );
          await owner.resources.writeBuffer(input, values);
          final output = await owner.resources.createBuffer(
            BufferDescriptor(
              size: samples.length * 32,
              usage: {BufferUsage.storage, BufferUsage.copySource},
            ),
          );
          final program = await owner.shaders.compile(
            ShaderSource.wgsl("""
${cloudMediaMathWgsl(q)}
$cloudFrameWgsl
$cloudSamplingWgsl
const PI:f32=3.141592653589793;
fn atmosphereSunIrradiance(p:vec3<f32>,n:vec3<f32>,s:vec3<f32>)->vec3<f32>{return vec3<f32>(1.,.9,.8);}
fn atmosphereSkyIrradiance(p:vec3<f32>,n:vec3<f32>,s:vec3<f32>)->vec3<f32>{return vec3<f32>(.2,.3,.4)/(2.*PI);}
fn cloudShadowDepth(p:vec3<f32>,d:f32,r:f32,j:f32)->f32{return 0.;}
${cloudRenderWgsl(q).split('fn cloudHaze(').first}
@group(0) @binding(0) var<storage,read> inputs:array<vec4<f32>>;
@group(0) @binding(1) var<storage,read_write> output:array<vec4<f32>>;
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id:vec3<u32>){
 let p=inputs[id.x*3u];let d=inputs[id.x*3u+1u];let values=inputs[id.x*3u+2u];
 let value=cloudMarch(p.xyz,d.xyz,vec2<f32>(p.w,d.w),dot(d.xyz,cf.sun.xyz),values.x,values.y);output[id.x*2u]=value.color;output[id.x*2u+1u]=vec4<f32>(value.depth,0.,0.,0.);
}
"""),
          );
          final resources = <GpuResource>[
            pass.media,
            pass.frame,
            ...pass.textures.textures.resources,
            input,
            output,
          ];
          final graph = await owner.graphs.compile(
            GraphDescription(
              inputs: resources,
              passes: [
                ComputePassDescriptor(
                  name: 'source shadow rays',
                  program: program,
                  bindings: ShaderBindings([
                    ...pass.bindings,
                    BufferBinding.storageRead(0, input),
                    BufferBinding.storageReadWrite(1, output),
                  ]),
                  reads: resources,
                  writes: [output],
                  workgroups: Workgroups(samples.length),
                ),
              ],
            ),
          );
          await graph.execute();
          final bytes = ByteData.sublistView(
            await owner.resources.readBuffer(output),
          );
          final errors = List.filled(5, 0.0);
          for (var i = 0; i < samples.length; i++) {
            for (var c = 0; c < 5; c++) {
              final actual = bytes.getFloat32((i * 8 + c) * 4, Endian.little),
                  expected = (samples[i]['expected'][c] as num).toDouble();
              final error = (actual - expected).abs();
              if (error > errors[c]) errors[c] = error;
              expect(
                error,
                lessThan((c == 4 ? .15 : .00015)),
                reason: 'ray $i channel $c: $actual versus $expected',
              );
            }
          }
          print('Cloud march source errors $errors');
        } finally {
          await owner.close();
          expect((await backend.resourceStats()).residentBytes, 0);
          await backend.close();
        }
      },
    );
  }
}
