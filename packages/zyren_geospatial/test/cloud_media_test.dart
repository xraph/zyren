import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial/src/clouds/media_wgsl.dart';
import 'package:zyren_geospatial/src/clouds/media_uniforms.dart';
import 'package:zyren_native/zyren_native.dart';

CloudParameters referenceParameters() => CloudParameters(
  coverage: .6,
  scatteringCoefficient: .8,
  absorptionCoefficient: .2,
  localWeatherOffset: (.012, -.024),
  shapeOffset: const Vec3(.1, .2, .3),
  shapeDetailOffset: const Vec3(.2, .3, .4),
  layers: CloudLayers([
    CloudLayer(altitude: 750, height: 650, shadow: true),
    CloudLayer(
      channel: 1,
      altitude: 1000,
      height: 1200,
      weatherExponent: 2,
      shadow: true,
    ),
    CloudLayer(
      channel: 2,
      altitude: 7500,
      height: 500,
      densityScale: .003,
      shapeAmount: .4,
      shapeDetailAmount: 0,
      coverageFilterWidth: .5,
    ),
    CloudLayer(
      channel: 3,
      altitude: 2000,
      height: 1200,
      densityScale: .1,
      shapeAmount: .6,
      shapeDetailAmount: .5,
      weatherExponent: .5,
      coverageFilterWidth: .7,
      densityProfile: CloudDensityProfile(
        expTerm: .1,
        exponent: -2,
        linearTerm: .75,
        constantTerm: .25,
      ),
    ),
  ]),
);

void main() {
  test('cloud lighting defaults and bounded animated uniforms', () {
    final a = CloudAppearance();
    expect(
      [
        a.skyLightScale,
        a.groundBounceScale,
        a.powderScale,
        a.powderExponent,
        a.hazeDensityScale,
        a.hazeExponent,
        a.hazeScatteringCoefficient,
        a.hazeAbsorptionCoefficient,
        a.scatterAnisotropy1,
        a.scatterAnisotropy2,
        a.scatterAnisotropyMix,
        a.maxShadowFilterRadius,
      ],
      [1, 1, .8, 150, 3e-5, .001, .9, .5, .7, -.2, .5, 6],
    );
    expect(() => CloudAppearance(scatterAnisotropy1: 1), throwsArgumentError);
    expect(() => CloudAppearance(hazeExponent: 0), throwsArgumentError);
    expect(() => CloudAppearance(powderScale: double.nan), throwsArgumentError);
    expect(
      () => CloudAppearance(maxShadowFilterRadius: 33),
      throwsArgumentError,
    );
    final p = CloudParameters(
      layers: CloudLayers(),
      localWeatherVelocity: (.001, -.002),
      shapeVelocity: const Vec3(.01, .02, .03),
    );
    final u = cloudMediaUniforms(p, a, elapsed: 100);
    expect(u.length, 100);
    expect(u.sublist(8, 12), everyElement(0));
    expect(u[62], closeTo(.1, 1e-7));
    expect(u[63], closeTo(-.2, 1e-7));
    expect(u.sublist(68, 71), [1, 2, 3]);
    expect(
      () => cloudMediaUniforms(p, a, elapsed: double.infinity),
      throwsArgumentError,
    );
  });

  test(
    'native media, phase and structured sampling match original cloud GLSL',
    () async {
      final fixture = jsonDecode(
        File('test/fixtures/clouds/media.json').readAsStringSync(),
      );
      final samples = fixture['samples'] as List;
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      try {
        final uniforms = cloudMediaUniforms(
          referenceParameters(),
          CloudAppearance(),
        );
        final uniform = await owner.resources.createBuffer(
          BufferDescriptor(
            size: uniforms.lengthInBytes,
            usage: {BufferUsage.uniform, BufferUsage.copyDestination},
          ),
        );
        await owner.resources.writeBuffer(uniform, uniforms);
        final inputs = Float32List.fromList([
          for (final s in samples) ...[
            ...(s['position'] as List).cast<num>().map((v) => v.toDouble()),
            (s['height'] as num).toDouble(),
            ...(s['weather'] as List).cast<num>().map((v) => v.toDouble()),
            (s['shape'] as num).toDouble(),
            (s['detail'] as num).toDouble(),
            (s['mip'] as num).toDouble(),
            (s['jitter'] as num).toDouble(),
            ...(s['direction'] as List).cast<num>().map((v) => v.toDouble()),
            0.0,
          ],
        ]);
        final input = await owner.resources.createBuffer(
          BufferDescriptor(
            size: inputs.lengthInBytes,
            usage: {BufferUsage.storage, BufferUsage.copyDestination},
          ),
        );
        await owner.resources.writeBuffer(input, inputs);
        final output = await owner.resources.createBuffer(
          BufferDescriptor(
            size: samples.length * 24 * 4,
            usage: {BufferUsage.storage, BufferUsage.copySource},
          ),
        );
        final program = await owner.shaders.compile(
          ShaderSource.wgsl('''
${cloudMediaMathWgsl(CloudQuality.forPreset(CloudQualityPreset.high))}
@group(0) @binding(0) var<storage,read> inputs:array<vec4<f32>>;
@group(0) @binding(1) var<storage,read_write> output:array<f32>;
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id:vec3<u32>){
 let p=inputs[id.x*4u]; let texel=inputs[id.x*4u+1u];let args=inputs[id.x*4u+2u];let direction=inputs[id.x*4u+3u].xyz;
 let uv=cloudGlobeUv(p.xyz);let weather=cloudWeather(texel,p.w,false);
 let medium=cloudMedium(weather,args.x,args.y,args.z,args.w);
 let normal=cloudStructureNormal(direction,args.w);let planes=cloudStructuredPlanes(normal,p.xyz,direction,100.);
 let offset=id.x*24u;output[offset]=uv.x;output[offset+1u]=uv.y;
 for(var i=0u;i<4u;i++){output[offset+2u+i]=weather.height[i];output[offset+6u+i]=weather.density[i];output[offset+10u+i]=medium.weight[i];}
 output[offset+14u]=medium.scattering;output[offset+15u]=medium.extinction;output[offset+16u]=cloudPhase(-1.+2.*f32(id.x)/95.,1.);
 output[offset+17u]=normal.x;output[offset+18u]=normal.y;output[offset+19u]=normal.z;
 output[offset+20u]=planes.x;output[offset+21u]=planes.y;output[offset+22u]=cloudMultipleScattering(0.,0.);output[offset+23u]=cloudMultipleScattering(2.,0.);
}
'''),
        );
        final graph = await owner.graphs.compile(
          GraphDescription(
            inputs: [uniform, input, output],
            passes: [
              ComputePassDescriptor(
                name: 'cloud source media',
                program: program,
                bindings: ShaderBindings([
                  BufferBinding.uniform(0, uniform, group: 2),
                  BufferBinding.storageRead(0, input),
                  BufferBinding.storageReadWrite(1, output),
                ]),
                reads: [uniform, input, output],
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
        var maxMediaError = 0.0, maxPlaneError = 0.0;
        for (var n = 0; n < samples.length; n++) {
          final expected = samples[n]['expected'] as List;
          for (var i = 0; i < 22; i++) {
            final value = result.getFloat32((n * 24 + i) * 4, Endian.little);
            expect(value.isFinite, isTrue, reason: 'sample $n/$i');
            final error = (value - ((expected[i] as num?)?.toDouble() ?? 0))
                .abs();
            if (i < 20) {
              if (error > maxMediaError) maxMediaError = error;
            } else {
              if (error > maxPlaneError) maxPlaneError = error;
            }
            expect(
              error,
              lessThan(
                i == 20
                    ? 1.1
                    : i == 21
                    ? .0001
                    : .00002,
              ),
              reason: 'sample $n/$i: $value versus ${expected[i]}',
            );
          }
          expect(
            result.getFloat32((n * 24 + 22) * 4, Endian.little),
            greaterThan(result.getFloat32((n * 24 + 23) * 4, Endian.little)),
          );
        }
        print(
          'Cloud media max error $maxMediaError; structured ECEF plane offset max error $maxPlaneError m',
        );
        int occupied(ByteData data) => [
          for (var n = 0; n < samples.length; n++)
            for (var layer = 0; layer < 4; layer++)
              data.getFloat32((n * 24 + 6 + layer) * 4, Endian.little),
        ].where((density) => density > 1e-6).length;
        final originalCount = occupied(result);
        expect(originalCount, greaterThan(0));
        for (final sparsity in [.5, 1.0, 0.0]) {
          await owner.resources.writeBuffer(
            uniform,
            cloudMediaUniforms(
              referenceParameters().copyWith(sparsity: sparsity),
              CloudAppearance(),
            ),
          );
          await graph.execute();
          final reduced = ByteData.sublistView(
            await owner.resources.readBuffer(output),
          );
          final count = occupied(reduced);
          if (sparsity == 1) {
            expect(count, 0);
          } else if (sparsity == 0) {
            expect(count, originalCount);
          } else {
            expect(count, inExclusiveRange(0, originalCount));
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
