import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

Future<void> main() async {
  final backend = await NativeBackend.create();
  final scene = backend.createResourceScope(label: 'scene');
  final plugin = backend.createResourceScope(label: 'effect');
  try {
    final positions = await scene.createBuffer(
      BufferDescriptor(
        label: 'triangle positions',
        size: 9 * Float32List.bytesPerElement,
        usage: {
          BufferUsage.vertex,
          BufferUsage.copyDestination,
          BufferUsage.copySource,
        },
      ),
    );
    final vertices = Float32List.fromList([-1, -1, 0, 1, -1, 0, 0, 1, 0]);
    await scene.writeBuffer(positions, vertices);
    final shared = await plugin.retain(positions);
    await scene.close();
    final bytes = await plugin.readBuffer(shared);
    final values = ByteData.sublistView(bytes);
    for (var i = 0; i < vertices.length; i++) {
      if (values.getFloat32(i * 4, Endian.little) != vertices[i]) {
        throw StateError(
          'Native buffer round trip failed at vertex component $i.',
        );
      }
    }
    final live = await backend.resourceStats();
    print('Native GPU verified ${vertices.length} float components.');
    print(
      'Scene closed; effect retains ${live.residentBytes} bytes in ${live.liveAllocations} allocation.',
    );
    await plugin.close();
    print(
      'Effect closed; ${(await backend.resourceStats()).residentBytes} bytes remain.',
    );
  } finally {
    await backend.close();
  }
}
