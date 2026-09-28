part of 'native_renderer.dart';

/// Native scene backends with scoped GPU work and device accounting.
abstract interface class NativeGpuBackend implements GraphBackend {
  Future<ResourceStats> resourceStats();
  Future<ShaderStats> shaderStats();
  Future<GraphCacheStats> graphStats();
}

/// Control channels implemented by the native worker and platform presenters.
enum NativeGpuCommand { resource, shader, graph }

/// A bounded native ABI response. Failure codes preserve resource error types.
final class NativeGpuReply {
  final int status;
  final Uint8List? bytes;
  final String? message;
  NativeGpuReply.success(Uint8List bytes)
    : status = 0,
      bytes = bytes.asUnmodifiableView(),
      message = null;
  NativeGpuReply.failure(this.status, String this.message) : bytes = null {
    if (status <= 0) throw ArgumentError.value(status, 'status');
  }
}

/// Native adapters serialize these commands with rendering on the same device.
typedef NativeGpuCommandSender =
    Future<NativeGpuReply> Function(
      NativeGpuCommand kind,
      Uint8List bytes,
      int responseCapacity,
    );

/// Scoped GPU services for one native presenter session. This object owns its
/// scopes and compilers, but the adapter owns and closes the native transport.
final class NativeGpuServices {
  final _NativeResourceDevice _device;
  final _resources = <ResourceScope>{};
  final _shaders = <ShaderCompiler>{};
  final _graphs = <GraphCompiler>{};
  bool _closed = false;
  Future<void>? _closing;
  NativeGpuServices.withTransport(NativeGpuCommandSender send)
    : _device = _NativeResourceDevice(send);

  void _checkOpen() {
    if (_closed) throw StateError('Native GPU services have closed.');
  }

  ResourceScope createResourceScope({String label = ''}) {
    _checkOpen();
    final scope = ResourceScope(_device, label: label);
    _resources.add(scope);
    scope.whenClosed.then((_) => _resources.remove(scope));
    return scope;
  }

  ShaderCompiler createShaderCompiler({String label = ''}) {
    _checkOpen();
    final compiler = ShaderCompiler(_device, label: label);
    _shaders.add(compiler);
    compiler.whenClosed.then((_) => _shaders.remove(compiler));
    return compiler;
  }

  GraphCompiler createGraphCompiler({String label = ''}) {
    _checkOpen();
    final compiler = GraphCompiler(_device, label: label);
    _graphs.add(compiler);
    compiler.whenClosed.then((_) => _graphs.remove(compiler));
    return compiler;
  }

  /// Holds the scene's graph and mesh programs until the native frame completes.
  /// The original scene packet stays immutable.
  Future<T> submitFrame<T>(
    FrameSubmission submission,
    Uint8List packet,
    Future<T> Function(Uint8List bytes) submit,
  ) => _device.submitFrame(submission, packet, submit);

  Future<ResourceStats> resourceStats() => _device.stats();
  Future<ShaderStats> shaderStats() => _device.shaderStats();
  Future<GraphCacheStats> graphStats() => _device.graphStats();

  /// Stops admission immediately. Await before destroying the native session.
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    final errors = <Object>[];
    final work = [
      for (final compiler in _graphs.toList()) compiler.close(),
      for (final compiler in _shaders.toList()) compiler.close(),
      for (final scope in _resources.toList()) scope.close(),
    ];
    await Future.wait(
      work.map(
        (pending) => pending.then<void>(
          (_) {},
          onError: (Object error, StackTrace _) {
            errors.add(error);
          },
        ),
      ),
    );
    if (errors.isNotEmpty) throw ScopeCleanupException(errors);
  }
}

NativeGpuCommandSender _workerGpuSender(WorkerSession worker) =>
    (kind, bytes, capacity) async {
      final result =
          await worker.request(kind.name, [
                TransferableTypedData.fromList([bytes]),
                capacity,
              ])
              as List<Object>;
      return result[0] == 0
          ? NativeGpuReply.success(
              (result[1] as TransferableTypedData).materialize().asUint8List(),
            )
          : NativeGpuReply.failure(result[0] as int, result[1] as String);
    };
