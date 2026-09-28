import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'LUT cache shares device work, rejects cancelled candidates and retires workspace',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final cache = AtmosphereLutCache(owner, maxEntries: 2);
      final earth = AtmosphereParameters.legacy();
      final zero = earth.copyWith(
        rayleighScattering: Vec3.zero,
        mieScattering: Vec3.zero,
        mieExtinction: Vec3.zero,
        absorptionExtinction: Vec3.zero,
      );
      try {
        final first = cache.acquire(
          parameters: earth,
          quality: AtmosphereQuality.balanced,
        );
        final second = cache.acquire(
          parameters: earth,
          quality: AtmosphereQuality.balanced,
        );
        final a = await first, b = await second;
        expect(a.luts, same(b.luts));
        expect(cache.entryCount, 1);
        expect(
          (await backend.resourceStats()).residentBytes,
          AtmosphereQuality.balanced.residentBytes,
        );
        var checks = 0;
        await expectLater(
          cache.acquire(
            parameters: zero,
            quality: AtmosphereQuality.balanced,
            isCancelled: () => ++checks > 6,
          ),
          throwsStateError,
        );
        expect(cache.entryCount, 1);
        expect(a.luts.isClosed, isFalse);
        final vacuum = await cache.acquire(
          parameters: zero,
          quality: AtmosphereQuality.balanced,
        );
        final read = owner.resources;
        for (final entry in vacuum.luts.textures.entries) {
          final retained = await read.retain(entry.value);
          final data = ByteData.sublistView(await read.readTexture(retained));
          for (var i = 0; i < data.lengthInBytes; i += 16) {
            for (var c = 0; c < 3; c++) {
              expect(
                data.getFloat32(i + c * 4, Endian.little),
                closeTo(entry.key == 'transmittance' ? 1 : 0, 1e-6),
              );
            }
          }
        }
        await expectLater(
          cache.acquire(
            parameters: earth.copyWith(groundAlbedo: const Vec3(.2, .2, .2)),
            quality: AtmosphereQuality.balanced,
          ),
          throwsStateError,
        );
        await a.close();
        await b.close();
        await vacuum.close();
        final changed = await cache.acquire(
          parameters: earth.copyWith(groundAlbedo: const Vec3(.2, .2, .2)),
          quality: AtmosphereQuality.balanced,
        );
        expect(a.luts.isClosed, isTrue);
        expect(changed.luts.isClosed, isFalse);
        await changed.close();
        await cache.close();
        expect(cache.entryCount, 0);
        await expectLater(cache.acquire(parameters: earth), throwsStateError);
      } finally {
        await cache.close();
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: Timeout(Duration(minutes: 3)),
  );
  test(
    'closing a cache during precomputation drains partial native work',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final cache = AtmosphereLutCache(owner);
      try {
        final request = cache.acquire(
          parameters: AtmosphereParameters.legacy(),
          quality: AtmosphereQuality.balanced,
        );
        final checked = expectLater(request, throwsStateError);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        await cache.close();
        await checked;
        expect(cache.entryCount, 0);
        expect(owner.childCount, 0);
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await cache.close();
        await owner.close();
        await backend.close();
      }
    },
  );
  for (final quality in AtmosphereQuality.values) {
    test(
      '${quality.name} native Bruneton tables match original GLSL four-order reference',
      () async {
        final backend = await NativeBackend.create();
        final resources = backend.createResourceScope();
        final shaders = backend.createShaderCompiler();
        final graphs = backend.createGraphCompiler();
        try {
          final tables = await AtmosphereLuts.generate(
            resources: resources,
            shaders: shaders,
            graphs: graphs,
            parameters: AtmosphereParameters.legacy(),
            quality: quality,
          );
          final reference =
              jsonDecode(
                    File(
                      'test/fixtures/atmosphere/scattering-balanced.json',
                    ).readAsStringSync(),
                  )
                  as Map;
          final maxima = <String, double>{};
          for (final entry in tables.textures.entries) {
            final bytes = ByteData.sublistView(
              await resources.readTexture(entry.value),
            );
            if (Platform.environment['ATMOSPHERE_DUMP'] case final prefix?) {
              File('$prefix-${quality.name}-${entry.key}.bin').writeAsBytesSync(
                bytes.buffer.asUint8List(
                  bytes.offsetInBytes,
                  bytes.lengthInBytes,
                ),
              );
            }
            for (var i = 0; i < bytes.lengthInBytes; i += 16) {
              for (var c = 0; c < 3; c++) {
                final value = bytes.getFloat32(i + c * 4, Endian.little);
                expect(
                  value.isFinite && value >= 0,
                  isTrue,
                  reason: '${entry.key}: $i channel $c: $value',
                );
                if (entry.key == 'transmittance') {
                  expect(value, lessThanOrEqualTo(1.00001));
                }
              }
            }
            if (['rayleigh', 'mie', 'higher'].contains(entry.key)) {
              for (var x = 0; x < quality.scatteringWidth; x++) {
                final index =
                    ((quality.radiusSize - 1) * quality.viewSize +
                            quality.viewSize ~/ 2) *
                        quality.scatteringWidth +
                    x;
                for (var c = 0; c < 3; c++) {
                  expect(
                    bytes.getFloat32(index * 16 + c * 4, Endian.little),
                    0,
                    reason: 'top outward ray ${entry.key} x$x',
                  );
                }
              }
            }
            for (final sample in reference['tables'][entry.key] as List) {
              final offset = (sample['index'] as int) * 16;
              for (var c = 0; c < 3; c++) {
                final actual = bytes.getFloat32(offset + c * 4, Endian.little);
                final expected = (sample['rgb'][c] as num).toDouble();
                final error = (actual - expected).abs();
                maxima[entry.key] = math.max(maxima[entry.key] ?? 0, error);
                expect(
                  actual,
                  closeTo(
                    expected,
                    (entry.key == 'higher' ? .008 : .0002) +
                        expected.abs() * (entry.key == 'rayleigh' ? .025 : .02),
                  ),
                  reason: '${entry.key} ${sample['index']} channel $c',
                );
              }
            }
          }
          print('Bruneton ${quality.name} absolute error: $maxima');
          final probes = reference['radiance'] as List;
          final coords = await resources.createBuffer(
            BufferDescriptor(
              size: probes.length * 16,
              usage: {BufferUsage.storage, BufferUsage.copyDestination},
            ),
          );
          await resources.writeBuffer(
            coords,
            Float32List.fromList([
              for (final probe in probes)
                for (final value in probe['coordinates'] as List)
                  (value as num).toDouble(),
            ]),
          );
          final output = await resources.createBuffer(
            BufferDescriptor(
              size: probes.length * 16,
              usage: {BufferUsage.storage, BufferUsage.copySource},
            ),
          );
          final module = tables.shader(group: 0);
          final program = await shaders.compile(
            ShaderSource.wgsl(
              '''${module.source}@group(0) @binding(5) var<storage,read> coords:array<vec4<f32>>;
@group(0) @binding(6) var<storage,read_write> output:array<vec4<f32>>;
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id:vec3<u32>){
 let c=coords[id.x];let ground=hitsGround(c.x,c.y);
 output[id.x]=vec4<f32>(totalScattering(c.x,c.y,c.z,c.w,ground),1.);
}
''',
            ),
          );
          final graph = await graphs.compile(
            GraphDescription(
              inputs: [...tables.textures.values, coords, output],
              passes: [
                ComputePassDescriptor(
                  name: 'physical radiance probes',
                  program: program,
                  bindings: ShaderBindings([
                    ...module.bindings.entries,
                    BufferBinding.storageRead(5, coords),
                    BufferBinding.storageReadWrite(6, output),
                  ]),
                  reads: [...tables.textures.values, coords, output],
                  writes: [output],
                  workgroups: Workgroups(probes.length),
                ),
              ],
            ),
          );
          await graph.execute();
          final result = ByteData.sublistView(
            await resources.readBuffer(output),
          );
          var maxRadianceError = 0.0;
          for (var i = 0; i < probes.length; i++) {
            for (var c = 0; c < 3; c++) {
              final actual = result.getFloat32(i * 16 + c * 4, Endian.little),
                  expected = (probes[i]['rgb'][c] as num).toDouble();
              maxRadianceError = math.max(
                maxRadianceError,
                (actual - expected).abs(),
              );
              expect(
                actual,
                closeTo(expected, .002 + expected * .03),
                reason: 'radiance $i channel$c',
              );
            }
          }
          print(
            'Bruneton ${quality.name} physical radiance maximum error: $maxRadianceError',
          );
          final runtime = reference['runtime'] as List;
          final cases = [
            for (final item in runtime) item['input'] as List,
            [6360.01, .5, .8, 0.0],
            [6500.0, -.1, .5, -1.0],
            [6500.0, -.1, .5, 10.0],
            [6300.0, 1.0, .5, 1.0],
          ];
          final inputs = await resources.createBuffer(
            BufferDescriptor(
              size: cases.length * 16,
              usage: {BufferUsage.storage, BufferUsage.copyDestination},
            ),
          );
          await resources.writeBuffer(
            inputs,
            Float32List.fromList([
              for (final values in cases)
                for (final x in values) (x as num).toDouble(),
            ]),
          );
          final outputs = await resources.createBuffer(
            BufferDescriptor(
              size: cases.length * 32,
              usage: {BufferUsage.storage, BufferUsage.copySource},
            ),
          );
          final runtimeProgram = await shaders.compile(
            ShaderSource.wgsl('''
${module.source}
@group(0) @binding(5) var<storage,read> coords:array<vec4<f32>>;
@group(0) @binding(6) var<storage,read_write> output:array<vec4<f32>>;
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id:vec3<u32>){
 let c=coords[id.x];let origin=vec3<f32>(0.,0.,c.x);let ray=vec3<f32>(sqrt(1.-c.y*c.y),0.,c.y);let sun=vec3<f32>(sqrt(1.-c.z*c.z),0.,c.z);
 var sample=emptyAtmosphere();
 if(c.w<0.){sample=atmosphereSky(origin,ray,sun,false);}else{sample=atmosphereSegment(origin,origin+ray*c.w,sun);}
 output[id.x*2u]=vec4<f32>(sample.radiance,1.);output[id.x*2u+1u]=vec4<f32>(sample.transmittance,1.);
}
'''),
          );
          final runtimeGraph = await graphs.compile(
            GraphDescription(
              inputs: [...tables.textures.values, inputs, outputs],
              passes: [
                ComputePassDescriptor(
                  name: 'runtime paths',
                  program: runtimeProgram,
                  bindings: ShaderBindings([
                    ...module.bindings.entries,
                    BufferBinding.storageRead(5, inputs),
                    BufferBinding.storageReadWrite(6, outputs),
                  ]),
                  reads: [...tables.textures.values, inputs, outputs],
                  writes: [outputs],
                  workgroups: Workgroups(cases.length),
                ),
              ],
            ),
          );
          await runtimeGraph.execute();
          final runtimeData = ByteData.sublistView(
            await resources.readBuffer(outputs),
          );
          for (var i = 0; i < cases.length; i++) {
            for (var c = 0; c < 3; c++) {
              final expected = i < runtime.length
                  ? (runtime[i]['radiance'][c] as num).toDouble()
                  : 0.0;
              final transmission = i < runtime.length
                  ? (runtime[i]['transmittance'][c] as num).toDouble()
                  : 1.0;
              expect(
                runtimeData.getFloat32(i * 32 + c * 4, Endian.little),
                closeTo(expected, .002 + expected.abs() * .04),
                reason: 'runtime radiance $i/$c',
              );
              expect(
                runtimeData.getFloat32(i * 32 + 16 + c * 4, Endian.little),
                closeTo(transmission, .003),
                reason: 'runtime transmission $i/$c',
              );
            }
          }
        } finally {
          await graphs.close();
          await shaders.close();
          await resources.close();
          expect((await backend.resourceStats()).residentBytes, 0);
          await backend.close();
        }
      },
      timeout: Timeout(Duration(minutes: 3)),
    );
  }
}
