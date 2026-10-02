import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  final path = Platform.environment['ZYREN_SOURCE_LUTS'];
  for (final packed in [true, false]) {
    for (final higher in [true, false]) {
      for (final format in AtmosphereLutFormat.values) {
        test(
          'native $format packed=$packed higher=$higher source tables match upstream runtime',
          () async {
            final reference =
                jsonDecode(
                      File(
                        'test/fixtures/atmosphere/scattering-source-${packed ? 'packed' : 'full'}.json',
                      ).readAsStringSync(),
                    )
                    as Map;
            final source = PrecomputedAtmosphereSource(
              baseUri: Directory(path!).uri,
              services: AssetServices(resolver: NativeSourceResolver()),
              format: format,
              combinedScattering: packed,
              higherOrderScattering: higher,
            );
            final backend = await NativeBackend.create();
            final owner = GpuScope.fromBackend(backend);
            final cache = AtmosphereLutCache(owner);
            try {
              final requests = [
                cache.acquire(parameters: source.parameters, source: source),
                cache.acquire(parameters: source.parameters, source: source),
              ];
              final a = await requests[0], b = await requests[1];
              final tables = a.luts;
              expect(tables, same(b.luts));
              expect(tables.quality, isNull);
              expect(tables.dimensions.radiusSize, 32);
              expect(tables.sourceScattering, isTrue);
              expect(tables.hasHigherOrderScattering, higher);
              expect(
                (await backend.resourceStats()).residentBytes,
                source.decodedBytes + (packed ? 8 : 0) + (higher ? 0 : 8),
              );
              final runtime = reference['runtime'] as List;
              final inputs = await owner.resources.createBuffer(
                BufferDescriptor(
                  size: runtime.length * 16,
                  usage: {BufferUsage.storage, BufferUsage.copyDestination},
                ),
              );
              final output = await owner.resources.createBuffer(
                BufferDescriptor(
                  size: runtime.length * 32,
                  usage: {BufferUsage.storage, BufferUsage.copySource},
                ),
              );
              await owner.resources.writeBuffer(
                inputs,
                Float32List.fromList([
                  for (final row in runtime)
                    for (final n in row['input'] as List) (n as num).toDouble(),
                ]),
              );
              final shader = tables.shader();
              final program = await owner.shaders.compile(
                ShaderSource.wgsl('''
${shader.source}
@group(0) @binding(0) var<storage,read> coords:array<vec4<f32>>;
@group(0) @binding(1) var<storage,read_write> output:array<vec4<f32>>;
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id:vec3<u32>){
 let c=coords[id.x];let origin=vec3<f32>(0.,0.,c.x);let ray=vec3<f32>(sqrt(1.-c.y*c.y),0.,c.y);let sun=vec3<f32>(sqrt(1.-c.z*c.z),0.,c.z);
 var value=emptyAtmosphere();
 if(c.w<0.){value=atmosphereSky(origin,ray,sun,false);}else{value=atmosphereSegment(origin,origin+ray*c.w,sun);}
 output[id.x*2u]=vec4<f32>(value.radiance,1.);output[id.x*2u+1u]=vec4<f32>(value.transmittance,1.);
}
'''),
              );
              final graph = await owner.graphs.compile(
                GraphDescription(
                  inputs: [...tables.textures.values, inputs, output],
                  passes: [
                    ComputePassDescriptor(
                      name: 'source atmosphere runtime',
                      program: program,
                      bindings: ShaderBindings([
                        ...shader.bindings.entries,
                        BufferBinding.storageRead(0, inputs),
                        BufferBinding.storageReadWrite(1, output),
                      ]),
                      reads: [...tables.textures.values, inputs, output],
                      writes: [output],
                      workgroups: Workgroups(runtime.length),
                    ),
                  ],
                ),
              );
              await graph.execute();
              final data = ByteData.sublistView(
                await owner.resources.readBuffer(output),
              );
              var maximum = 0.0;
              for (var i = 0; i < runtime.length; i++) {
                for (var c = 0; c < 3; c++) {
                  final radiance = (runtime[i]['radiance'][c] as num)
                      .toDouble();
                  final tr = (runtime[i]['transmittance'][c] as num).toDouble();
                  final actual = data.getFloat32(i * 32 + c * 4, Endian.little);
                  final error = (actual - radiance).abs();
                  if (error > maximum) maximum = error;
                  expect(
                    actual,
                    closeTo(radiance, .0005 + radiance.abs() * .012),
                    reason: 'radiance $i/$c',
                  );
                  expect(
                    data.getFloat32(i * 32 + 16 + c * 4, Endian.little),
                    closeTo(tr, .003),
                    reason: 'transmittance $i/$c',
                  );
                }
              }
              print(
                'Source $format packed=$packed: max radiance error $maximum; ${source.decodedBytes + (packed ? 8 : 0) + (higher ? 0 : 8)} resident table bytes.',
              );
              await a.close();
              await b.close();
            } finally {
              await cache.close();
              await owner.close();
              expect((await backend.resourceStats()).residentBytes, 0);
              await backend.close();
            }
          },
          skip: path == null
              ? 'Set ZYREN_SOURCE_LUTS to pinned source assets.'
              : false,
        );
      }
    }
  }
}
