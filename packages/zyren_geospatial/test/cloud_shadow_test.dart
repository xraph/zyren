import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'package:zyren_geospatial/src/clouds/media_wgsl.dart';
import 'package:zyren_geospatial/src/clouds/sampling_wgsl.dart';
import 'package:zyren_geospatial/src/clouds/shadow_wgsl.dart';
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
  test('disabled shadows allocate no atlas, graph or shadow history', () async {
    final backend = await NativeBackend.create();
    final owner = GpuScope.fromBackend(backend);
    try {
      final textures = await constantCloudTextures(owner);
      final pass = await CloudShadowPass.build(
        owner,
        textures,
        CloudQuality.forPreset(CloudQualityPreset.ultra, shadowsEnabled: false),
        temporal: true,
      );
      expect(pass.atlas, isNull);
      expect(pass.graph, isNull);
      expect(pass.temporal, isNull);
      final camera = PerspectiveCamera(
        position: const Vec3(0, 0, 6360100),
        target: const Vec3(0, 10000, 6360100),
        up: const Vec3(0, 0, 1),
        near: 1,
        far: 20000,
      );
      final frame = CloudFrameState(
        camera: camera,
        worldToEcef: Mat4.identity(),
        correctedCamera: camera.position,
        sun: const Vec3(0, 0, 1),
        aspect: 1,
        width: 32,
        height: 32,
        shadowSize: pass.size,
        cascadeCount: 4,
        shadowsEnabled: false,
      );
      expect(frame.cascades.cascades, isEmpty);
      await pass.render(referenceParameters(), CloudAppearance(), frame);
    } finally {
      await owner.close();
      expect((await backend.resourceStats()).residentBytes, 0);
      await backend.close();
    }
  });
  test('Beer shadow rays match the original structured GLSL marcher', () async {
    final backend = await NativeBackend.create();
    final owner = GpuScope.fromBackend(backend);
    try {
      final textures = await constantCloudTextures(owner);
      final q = CloudQuality.forPreset(CloudQualityPreset.low);
      final pass = await CloudShadowPass.build(owner, textures, q, mapSize: 8);
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
          cascadeCount: 2,
        ),
      );
      final fixture = jsonDecode(
        File('test/fixtures/clouds/shadow.json').readAsStringSync(),
      );
      final samples = fixture['samples'] as List;
      final values = Float32List.fromList([
        for (final s in samples) ...[
          ...(s['origin'] as List).cast<num>().map((v) => v.toDouble()),
          (s['distance'] as num).toDouble(),
          ...(s['direction'] as List).cast<num>().map((v) => v.toDouble()),
          (s['jitter'] as num).toDouble(),
          (s['mip'] as num).toDouble(),
          0,
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
          size: samples.length * 16,
          usage: {BufferUsage.storage, BufferUsage.copySource},
        ),
      );
      final program = await owner.shaders.compile(
        ShaderSource.wgsl("""
${cloudMediaMathWgsl(q)}
$cloudFrameWgsl
$cloudSamplingWgsl
${cloudShadowMarchWgsl(q)}
@group(0) @binding(0) var<storage,read> inputs:array<vec4<f32>>;
@group(0) @binding(1) var<storage,read_write> output:array<vec4<f32>>;
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id:vec3<u32>){
 let p=inputs[id.x*3u];let d=inputs[id.x*3u+1u];let mip=inputs[id.x*3u+2u].x;
 output[id.x]=cloudMarchShadow(p.xyz,d.xyz,p.w,d.w,mip);
}
"""),
      );
      final resources = <GpuResource>[
        pass.media,
        pass.frame,
        pass.noise,
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
      final errors = List.filled(4, 0.0);
      for (var i = 0; i < samples.length; i++) {
        for (var c = 0; c < 4; c++) {
          final actual = bytes.getFloat32((i * 4 + c) * 4, Endian.little),
              expected = (samples[i]['expected'][c] as num).toDouble();
          final error = (actual - expected).abs();
          if (error > errors[c]) errors[c] = error;
          expect(
            error,
            lessThan([.02, .000025, .005, .00001][c]),
            reason: 'ray $i channel $c: $actual versus $expected',
          );
        }
      }
      print('Beer shadow source errors $errors');
    } finally {
      await owner.close();
      expect((await backend.resourceStats()).residentBytes, 0);
      await backend.close();
    }
  });

  test(
    'native cascaded Beer shadows respond to coverage and release retained maps',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final caller = owner.createChild();
      final textures = await constantCloudTextures(caller);
      final pass = await CloudShadowPass.build(
        owner,
        textures,
        CloudQuality.forPreset(CloudQualityPreset.low),
        mapSize: 16,
      );
      await caller.close();
      final camera = PerspectiveCamera(
        position: const Vec3(0, 0, 6360100),
        target: const Vec3(0, 10000, 6360100),
        up: const Vec3(0, 0, 1),
        near: 1,
        far: 20000,
      );
      CloudFrameState frame() => CloudFrameState(
        camera: camera,
        worldToEcef: Mat4.identity(),
        correctedCamera: camera.position,
        sun: const Vec3(0, 0, 1),
        aspect: 1,
        width: 16,
        height: 16,
        shadowSize: 16,
        cascadeCount: 2,
      );
      try {
        for (final coverage in [0.0, 1.0, 0.0]) {
          await pass.render(
            CloudParameters(coverage: coverage),
            CloudAppearance(),
            frame(),
          );
          final bytes = ByteData.sublistView(
            await pass.scope.resources.readTexture(pass.atlas!),
          );
          var occupied = 0;
          for (var i = 0; i < bytes.lengthInBytes; i += 16) {
            final values = [
              for (var c = 0; c < 4; c++)
                bytes.getFloat32(i + c * 4, Endian.little),
            ];
            expect(values.every((v) => v.isFinite && v >= 0), isTrue);
            if (values[1] > 0 && values[2] > 0) {
              occupied++;
              expect(values[3], lessThanOrEqualTo(500));
            }
          }
          if (coverage == 0) {
            expect(occupied, 0);
          } else {
            expect(occupied, greaterThan(100));
          }
        }
        final resident = (await backend.resourceStats()).residentBytes;
        camera.target = const Vec3(10000, 10000, 6360200);
        await pass.render(
          CloudParameters(
            coverage: 1,
            layers: CloudLayers([
              CloudLayer(altitude: 1000, height: 1000, shadow: false),
            ]),
          ),
          CloudAppearance(),
          frame(),
        );
        final bytes = ByteData.sublistView(
          await pass.scope.resources.readTexture(pass.atlas!),
        );
        for (var i = 0; i < bytes.lengthInBytes; i += 4) {
          expect(bytes.getFloat32(i, Endian.little), 0);
        }
        expect((await backend.resourceStats()).residentBytes, resident);
      } finally {
        await pass.close();
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );
}
