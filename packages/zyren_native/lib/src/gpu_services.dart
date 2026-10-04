part of 'native_renderer.dart';

/// Native scene backends with scoped GPU work and device accounting.
abstract interface class NativeGpuBackend
    implements MaterialBackend, GpuDiagnosticsBackend {
  Future<ResourceStats> resourceStats();
  Future<void> configureResourceBudget(int bytes);
  Future<ShaderStats> shaderStats();
  Future<GraphCacheStats> graphStats();
  Future<ShadowStats> shadowStats();
  Future<TemporalStats> temporalStats();
  Future<TransmissionStats> transmissionStats();
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
  final _materials = <MaterialCompiler>{};
  final _captures = <_NativeSceneCapture>{};
  bool _closed = false;
  Future<void>? _closing;
  NativeGpuServices.withTransport(NativeGpuCommandSender send)
    : _device = _NativeResourceDevice(send);

  void _checkOpen() {
    if (_closed) throw StateError('Native GPU services have closed.');
  }

  Future<SceneCaptureView> createCaptureView() async {
    _checkOpen();
    final view = await _NativeSceneCapture.create(_device);
    if (_closed) {
      await view.close();
      throw StateError('GPU services closed during capture creation.');
    }
    _captures.add(view);
    view.whenClosed.then((_) => _captures.remove(view));
    return view;
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

  MaterialCompiler createMaterialCompiler({String label = ''}) {
    _checkOpen();
    final compiler = MaterialCompiler(_device, label: label);
    _materials.add(compiler);
    compiler.whenClosed.then((_) => _materials.remove(compiler));
    return compiler;
  }

  ScenePacketEncoder createSceneEncoder({required int viewId}) {
    _checkOpen();
    return ScenePacketEncoder(viewId: viewId, materialDevice: _device);
  }

  Future<GpuInspection> inspectGpu({int allocationLimit = 128}) {
    _checkOpen();
    return _device.inspectGpu(allocationLimit: allocationLimit);
  }

  Future<NativeDeviceInfo> deviceInfo() => _device.deviceInfo();

  /// Leases the frame's bindings through native submission. A published native
  /// cover then owns references until replacement or view teardown, so you can
  /// close the Dart owners without blocking subsequent staging or disposal.
  /// Closed Dart owners cannot be used for new submissions. The encoder can
  /// still present their retained cover while a replacement is staged.
  /// The original scene packet stays immutable.
  Future<T> submitFrame<T>(
    FrameSubmission submission,
    Uint8List packet,
    Future<T> Function(Uint8List bytes) submit, {
    EncodedScenePacket? scenePacket,
  }) =>
      _device.submitFrame(submission, packet, submit, scenePacket: scenePacket);

  Future<Set<TextureFormat>> textureFormats() => _device.textureFormats();
  Future<ResourceStats> resourceStats() => _device.stats();
  int get resourceBudgetBytes => _device.resourceBudgetBytes;
  Future<void> configureResourceBudget(int bytes) {
    _checkOpen();
    return _device.configureBudget(bytes);
  }

  Future<NativeFrameProfile> frameProfile() => _device.frameProfile();

  /// Decode a profile captured on the presenter's serial render queue. The
  /// platform adapter uses the frame ID as the existing graph request ID.
  static NativeFrameProfile decodeFrameProfile(
    Uint8List response, {
    required int frameId,
  }) => NativeFrameProfile.fromJson(_decodeGraphResponse(response, frameId));

  Future<ShaderStats> shaderStats() => _device.shaderStats();
  Future<GraphCacheStats> graphStats() => _device.graphStats();
  Future<ShadowStats> shadowStats() => _device.shadowStats();
  Future<TemporalStats> temporalStats() => _device.temporalStats();

  Future<TransmissionStats> transmissionStats() => _device.transmissionStats();

  /// Stops admission immediately. Await before destroying the native session.
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    final errors = <Object>[];
    StackTrace? firstStack;
    void record(Object error, StackTrace stack) {
      errors.add(error);
      firstStack ??= stack;
    }

    if (_captures.isNotEmpty) {
      await Future.wait([
        for (final capture in _captures.toList())
          capture.close().then<void>((_) {}, onError: record),
      ]);
    }
    final work = [
      for (final compiler in _graphs.toList()) compiler.close(),
      for (final compiler in _materials.toList()) compiler.close(),
      for (final compiler in _shaders.toList()) compiler.close(),
      for (final scope in _resources.toList()) scope.close(),
    ];
    await Future.wait(
      work.map((pending) => pending.then<void>((_) {}, onError: record)),
    );
    if (errors.isNotEmpty) {
      Error.throwWithStackTrace(ScopeCleanupException(errors), firstStack!);
    }
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
