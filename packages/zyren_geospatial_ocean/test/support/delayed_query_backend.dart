import 'dart:async';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';

/// Lifecycle-only device. Output is zero, suitable only for zero-wind fixtures.
/// Numeric tests use NativeBackend instead.
final class DelayedQueryDevice implements MaterialDevice {
  final readStarted = Completer<void>(), releaseRead = Completer<void>();
  final allocations = <Object>{}, shaders = <Object>{}, graphs = <Object>{};
  @override
  Future<Object> createBuffer(BufferDescriptor descriptor) async {
    final key = Object();
    allocations.add(key);
    return key;
  }

  @override
  Future<void> release(Object key) async {
    allocations.remove(key);
  }

  @override
  Future<void> writeBuffer(Object key, int offset, Uint8List bytes) async {}
  @override
  Future<Uint8List> readBuffer(Object key, int offset, int length) async {
    if (!readStarted.isCompleted) readStarted.complete();
    await releaseRead.future;
    return Uint8List(length);
  }

  @override
  Future<ShaderBuild> compileShader(ShaderSource source) async {
    final key = Object();
    shaders.add(key);
    return ShaderBuild(
      key: key,
      entryPoints: const [
        ShaderEntryPoint(
          name: 'main',
          stage: ShaderStage.compute,
          workgroupSize: (64, 1, 1),
        ),
      ],
    );
  }

  @override
  Future<void> releaseShader(Object key) async {
    shaders.remove(key);
  }

  @override
  Future<Object> compileGraph(GraphDeviceDescription description) async {
    final key = Object();
    graphs.add(key);
    return key;
  }

  @override
  Future<GraphStats> executeGraph(Object key) async =>
      const GraphStats(passes: 1, dispatches: 1, drawCalls: 0);
  @override
  Future<void> releaseGraph(Object key) async {
    graphs.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected test device call: ${invocation.memberName}');
}

final class DelayedQueryBackend implements MaterialBackend {
  final device = DelayedQueryDevice();
  @override
  ResourceScope createResourceScope({String label = ''}) =>
      ResourceScope(device, label: label);
  @override
  ShaderCompiler createShaderCompiler({String label = ''}) =>
      ShaderCompiler(device, label: label);
  @override
  GraphCompiler createGraphCompiler({String label = ''}) =>
      GraphCompiler(device, label: label);
  @override
  MaterialCompiler createMaterialCompiler({String label = ''}) =>
      MaterialCompiler(device, label: label);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected test backend call: ${invocation.memberName}',
  );
}
