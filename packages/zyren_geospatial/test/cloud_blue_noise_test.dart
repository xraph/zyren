import 'dart:typed_data';
import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial/src/clouds/blue_noise_wgsl.dart';
import 'package:zyren_geospatial/src/clouds/frame.dart';
import 'package:zyren_native/zyren_native.dart';
import 'cloud_source_test.dart' show CloudCancellation;

void main() {
  test(
    'blue noise loading enforces limits, policy and physical cancellation',
    () async {
      final resolver = _NoiseSource();
      Future<CloudBlueNoise> load({
        AssetLimits limits = const AssetLimits(),
        CloudCancellation? cancellation,
      }) => CloudBlueNoise.load(
        services: AssetServices(resolver: resolver, limits: limits),
        cancellation: cancellation ?? CloudCancellation(),
        uri: Uri.parse('fixture://noise/map?key=secret'),
      );
      await expectLater(
        load(limits: AssetLimits(maxDecodedBytes: 1)),
        throwsA(isA<AssetLoadException>()),
      );
      expect(resolver.reads, 0);
      for (final failure in ['size', 'redirect', 'exception']) {
        resolver.failure = failure;
        await expectLater(
          load(),
          throwsA(
            isA<AssetLoadException>().having(
              (e) => e.toString().contains('secret'),
              'secret free',
              false,
            ),
          ),
        );
      }
      resolver.failure = '';
      resolver.gate = Completer<void>();
      final cancel = CloudCancellation();
      var settled = false;
      final job = load(cancellation: cancel);
      final expected = expectLater(job, throwsA(isA<LoadCancelled>()));
      unawaited(
        job.then<void>(
          (_) => settled = true,
          onError: (Object _) {
            settled = true;
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);
      cancel.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(settled, false);
      resolver.gate!.complete();
      await expected;
    },
  );
  test('blue noise validates its fixed volume and copies caller bytes', () {
    expect(() => CloudBlueNoise(Uint8List(1)), throwsArgumentError);
    final bytes = Uint8List(1048576)..[0] = 17;
    final noise = CloudBlueNoise(bytes);
    bytes[0] = 0;
    expect(noise.bytes[0], 17);
    expect(() => noise.bytes[0] = 0, throwsUnsupportedError);
  });
  test(
    'packed native blue noise preserves source pixel orientation and frame wrap',
    () async {
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      try {
        final bytes = Uint8List.fromList(
          List.generate(1048576, (i) => (i * 17 + i ~/ 128 + i ~/ 16384) % 256),
        );
        final noise = CloudBlueNoise(bytes);
        final buffer = await owner.resources.createBuffer(
          BufferDescriptor(
            size: bytes.length,
            usage: {BufferUsage.storage, BufferUsage.copyDestination},
          ),
        );
        await owner.resources.writeBuffer(buffer, noise.bytes);
        final frame = await owner.resources.createBuffer(
          BufferDescriptor(
            size: 800,
            usage: {BufferUsage.uniform, BufferUsage.copyDestination},
          ),
        );
        final values = Float32List(200);
        values[15] = 67;
        await owner.resources.writeBuffer(frame, values);
        final output = await owner.resources.createBuffer(
          BufferDescriptor(
            size: 64,
            usage: {BufferUsage.storage, BufferUsage.copySource},
          ),
        );
        final shader = await owner.shaders.compile(
          ShaderSource.wgsl('''
$cloudFrameWgsl
$cloudBlueNoiseWgsl
@group(0) @binding(0) var<storage,read_write> result:array<f32>;
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id:vec3<u32>){result[id.x]=cloudNoise(vec2<f32>(f32(id.x*17u),f32(id.x)),16.);}
'''),
        );
        final graph = await owner.graphs.compile(
          GraphDescription(
            inputs: [frame, buffer, output],
            passes: [
              ComputePassDescriptor(
                name: 'STBN samples',
                program: shader,
                bindings: ShaderBindings([
                  BufferBinding.uniform(5, frame, group: 2),
                  BufferBinding.storageRead(7, buffer, group: 2),
                  BufferBinding.storageReadWrite(0, output),
                ]),
                reads: [frame, buffer, output],
                writes: [output],
                workgroups: Workgroups(16),
              ),
            ],
          ),
        );
        await graph.execute();
        final result = ByteData.sublistView(
          await owner.resources.readBuffer(output),
        );
        for (var i = 0; i < 16; i++) {
          expect(
            result.getFloat32(i * 4, Endian.little),
            closeTo(
              bytes[3 * 16384 + (15 - i) * 128 + (i * 17) % 128] / 255,
              1e-7,
            ),
          );
        }
      } finally {
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );
}

class _NoiseSource implements ByteSourceResolver {
  int reads = 0;
  String failure = '';
  Completer<void>? gate;
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    reads++;
    await gate?.future;
    if (failure == 'exception') throw StateError('secret endpoint');
    return ResolvedSource(
      effectiveUri: failure == 'redirect'
          ? Uri.parse('https://other/secret')
          : uri,
      bytes: Uint8List(failure == 'size' ? 1 : 1048576),
    );
  }
}
