part of 'native_renderer.dart';

/// Serialized command transport for the native renderer owned by a host view.
/// The host runs commands on the same queue and device as scene presentation.
typedef NativeGpuTransport =
    Future<NativeGpuReply> Function(
      String operation,
      Uint8List bytes,
      int responseCapacity,
    );

final class NativeGpuReply {
  final int status;
  final Uint8List bytes;
  final String error;
  NativeGpuReply.success(this.bytes) : status = 0, error = '';
  NativeGpuReply.failure(this.status, this.error) : bytes = Uint8List(0) {
    if (status == 0) {
      throw ArgumentError('A failed command requires a nonzero status.');
    }
  }
}

/// Owns the public GPU scopes attached to one native host session.
/// Closing drains accepted work before the host destroys its renderer.
final class NativeGpuContext {
  final _NativeResourceDevice _device;
  final _resources = <ResourceScope>{};
  final _shaders = <ShaderCompiler>{};
  final _graphs = <GraphCompiler>{};
  final _materials = <MaterialCompiler>{};
  bool _closed = false;
  Future<void>? _closing;
  NativeGpuContext(NativeGpuTransport transport)
    : _device = _NativeResourceDevice(transport);
  void _checkOpen() {
    if (_closed) throw StateError('Native GPU context has closed.');
  }

  ResourceScope createResourceScope({String label = ''}) {
    _checkOpen();
    final value = ResourceScope(_device, label: label);
    _resources.add(value);
    value.whenClosed.then((_) => _resources.remove(value));
    return value;
  }

  ShaderCompiler createShaderCompiler({String label = ''}) {
    _checkOpen();
    final value = ShaderCompiler(_device, label: label);
    _shaders.add(value);
    value.whenClosed.then((_) => _shaders.remove(value));
    return value;
  }

  GraphCompiler createGraphCompiler({String label = ''}) {
    _checkOpen();
    final value = GraphCompiler(_device, label: label);
    _graphs.add(value);
    value.whenClosed.then((_) => _graphs.remove(value));
    return value;
  }

  Future<ResourceStats> resourceStats() => _device.stats();
  MaterialCompiler createMaterialCompiler({String label = ''}) {
    _checkOpen();
    final value = MaterialCompiler(_device, label: label);
    _materials.add(value);
    value.whenClosed.then((_) => _materials.remove(value));
    return value;
  }

  ScenePacketEncoder createSceneEncoder({required int viewId}) {
    _checkOpen();
    return ScenePacketEncoder(viewId: viewId, materialDevice: _device);
  }

  Future<ShaderStats> shaderStats() => _device.shaderStats();
  Future<GraphCacheStats> graphStats() => _device.graphStats();
  Future<void> close() {
    _closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    final failures = <Object>[];
    for (final close in [
      for (final graph in _graphs.toList()) graph.close,
      for (final material in _materials.toList()) material.close,
      for (final shader in _shaders.toList()) shader.close,
      for (final resource in _resources.toList()) resource.close,
    ]) {
      try {
        await close();
      } catch (error) {
        failures.add(error);
      }
    }
    if (failures.isNotEmpty) throw ScopeCleanupException(failures);
  }
}

NativeGpuTransport _workerTransport(WorkerSession worker) =>
    (operation, bytes, capacity) async {
      final reply =
          await worker.request(operation, [
                TransferableTypedData.fromList([bytes]),
                capacity,
              ])
              as List<Object>;
      return reply[0] == 0
          ? NativeGpuReply.success(
              (reply[1] as TransferableTypedData).materialize().asUint8List(),
            )
          : NativeGpuReply.failure(reply[0] as int, reply[1] as String);
    };
