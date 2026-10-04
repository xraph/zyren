import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'native graph capacity supports composed effects and remains bounded',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      try {
        final output = await owner.resources.createBuffer(
          BufferDescriptor(
            size: 4,
            usage: {BufferUsage.storage, BufferUsage.copySource},
          ),
        );
        final program = await owner.shaders.compile(
          ShaderSource.wgsl('''
@group(0) @binding(0) var<storage, read_write> result: array<u32>;
@compute @workgroup_size(1) fn main() { result[0] = 37u; }
'''),
        );
        Future<CompiledGraph> compile(GpuScope scope) async {
          final retained = await scope.resources.retain(output);
          return scope.graphs.compile(
            GraphDescription(
              passes: [
                ComputePassDescriptor(
                  name: 'write',
                  program: program,
                  workgroups: Workgroups(1),
                  reads: [retained],
                  writes: [retained],
                  bindings: ShaderBindings([
                    BufferBinding.storageReadWrite(0, retained),
                  ]),
                ),
              ],
              inputs: [retained],
            ),
          );
        }

        final scopes = <GpuScope>[], graphs = <CompiledGraph>[];
        for (var i = 0; i < 256; i++) {
          final scope = owner.createChild(label: 'effect-$i');
          scopes.add(scope);
          graphs.add(await compile(scope));
        }
        final excess = owner.createChild(label: 'over-capacity');
        await expectLater(compile(excess), throwsA(isA<GraphException>()));
        await graphs.first.execute();
        expect(
          ByteData.sublistView(
            await owner.resources.readBuffer(output),
          ).getUint32(0, Endian.little),
          37,
        );
        await scopes.last.close();
        final replacement = await compile(excess);
        await replacement.execute();
        expect(
          ByteData.sublistView(
            await owner.resources.readBuffer(output),
          ).getUint32(0, Endian.little),
          37,
        );
      } finally {
        await owner.close();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
