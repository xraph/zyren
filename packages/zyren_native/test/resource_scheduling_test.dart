import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'consecutive writes coalesce without crossing graph boundaries',
    () async {
      final backend = await NativeBackend.create();
      final scope = backend.createResourceScope();
      final shaders = backend.createShaderCompiler();
      final compiler = backend.createGraphCompiler();
      try {
        final params = await scope.createBuffer(
          BufferDescriptor(
            size: 16,
            usage: {BufferUsage.uniform, BufferUsage.copyDestination},
          ),
        );
        final values = await scope.createBuffer(
          BufferDescriptor(
            size: 16,
            usage: {BufferUsage.storage, BufferUsage.copySource},
          ),
        );
        final program = await shaders.compile(
          ShaderSource.wgsl('''
@group(0) @binding(0) var<uniform> params: vec4<u32>;
@group(0) @binding(1) var<storage, read_write> values: array<u32>;
@compute @workgroup_size(1) fn main() { values[params.x] = params.y; }
'''),
        );
        final graph = await compiler.compile(
          GraphDescription(
            inputs: [params, values],
            passes: [
              ComputePassDescriptor(
                name: 'record',
                program: program,
                workgroups: const Workgroups(1),
                bindings: ShaderBindings([
                  BufferBinding.uniform(0, params),
                  BufferBinding.storageReadWrite(1, values),
                ]),
                reads: [params, values],
                writes: [values],
              ),
            ],
          ),
        );
        await scope.writeBuffer(params, Uint32List.fromList([0, 1, 0, 0]));
        await scope.writeBuffer(params, Uint32List.fromList([2]), offset: 4);
        expect(
          (await backend.inspectGpu())
              .frameProfile!
              .resources['submissionCount'],
          0,
        );
        await graph.execute();
        expect(
          (await backend.inspectGpu())
              .frameProfile!
              .resources['submissionCount'],
          1,
        );
        await scope.writeBuffer(params, Uint32List.fromList([1, 7, 0, 0]));
        await graph.execute();
        final profile = (await backend.inspectGpu()).frameProfile!.resources;
        expect(profile['submissionCount'], 2);
        expect(profile['graphSubmissionCount'], 2);
        expect(profile['cpuCompletionWaitNs'], 0);
        final bytes = ByteData.sublistView(await scope.readBuffer(values));
        expect(
          [
            bytes.getUint32(0, Endian.little),
            bytes.getUint32(4, Endian.little),
          ],
          [2, 7],
        );
        await compiler.close();
        await scope.close();
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await compiler.close();
        await shaders.close();
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'pending writes respect count and byte bounds and release flushes them',
    () async {
      final backend = await NativeBackend.create();
      final scope = backend.createResourceScope();
      try {
        final buffer = await scope.createBuffer(
          BufferDescriptor(
            size: 36 * 1024 * 1024,
            usage: {BufferUsage.copyDestination, BufferUsage.copySource},
          ),
        );
        for (var i = 0; i < 257; i++) {
          await scope.writeBuffer(buffer, Uint32List.fromList([i]));
        }
        var profile = (await backend.inspectGpu()).frameProfile!.resources;
        expect(profile['submissionCount'], 1);
        expect(profile['pendingWriteCount'], 1);
        final data = Uint8List(36 * 1024 * 1024)..[0] = 7;
        await scope.writeBuffer(buffer, data);
        await scope.writeBuffer(buffer, data);
        profile = (await backend.inspectGpu()).frameProfile!.resources;
        expect(profile['submissionCount'], 2);
        expect(profile['pendingWriteBytes'], 36 * 1024 * 1024);
        expect(profile['pendingWriteCount'], 1);
        await scope.close();
        profile = (await backend.inspectGpu()).frameProfile!.resources;
        expect(profile['submissionCount'], 3);
        expect(profile['pendingWriteCount'], 0);
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'texture writes coalesce into readback and preserve their last value',
    () async {
      final backend = await NativeBackend.create();
      final scope = backend.createResourceScope();
      try {
        final texture = await scope.createTexture(
          TextureDescriptor(
            width: 1,
            height: 1,
            usage: {TextureUsage.copyDestination, TextureUsage.copySource},
            format: TextureFormat.rgba8Unorm,
          ),
        );
        await scope.writeTexture(texture, Uint8List.fromList([255, 0, 0, 255]));
        await scope.writeTexture(texture, Uint8List.fromList([0, 255, 0, 255]));
        expect(
          (await backend.inspectGpu())
              .frameProfile!
              .resources['submissionCount'],
          0,
        );
        expect(await scope.readTexture(texture), [0, 255, 0, 255]);
        final profile = (await backend.inspectGpu()).frameProfile!.resources;
        expect(profile['submissionCount'], 1);
        expect(profile['pendingWriteCount'], 0);
      } finally {
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
