part of 'native_renderer.dart';

final class _NativeSceneCapture implements SceneCaptureView {
  final _NativeResourceDevice _device;
  ScenePacketEncoder _encoder;
  final _closedSignal = Completer<void>();
  Future<void> get whenClosed => _closedSignal.future;
  Future<SceneCaptureReceipt>? _pending;
  Future<void>? _closing, _clearing;
  bool _closed = false;
  _NativeSceneCapture._(this._device, int view)
    : _encoder = ScenePacketEncoder(viewId: view, materialDevice: _device);

  static Future<_NativeSceneCapture> create(
    _NativeResourceDevice device,
  ) async {
    final bytes = await device._command(
      100,
      _ResourcePacket(),
      responseBytes: 8,
    );
    return _NativeSceneCapture._(
      device,
      ByteData.sublistView(bytes).getUint64(0, Endian.little),
    );
  }

  @override
  void configureSceneUploadBudget(int bytes) {
    if (_closed) throw StateError('Capture view has closed.');
    _encoder.uploadBudgetBytes = bytes;
  }

  @override
  Future<void> clear() {
    if (_closed) return Future.error(StateError('Capture view has closed.'));
    return _clearing ??= _clear().whenComplete(() => _clearing = null);
  }

  Future<void> _clear() async {
    try {
      await _pending;
    } catch (_) {
      /* Release a rejected cover too. */
    }
    final view = _encoder.viewId, budget = _encoder.uploadBudgetBytes;
    await _device._command(105, _ResourcePacket()..u64(view));
    _encoder = ScenePacketEncoder(viewId: view, materialDevice: _device)
      ..uploadBudgetBytes = budget;
  }

  @override
  Future<SceneCaptureReceipt> capture(
    FrameSubmission submission,
    GpuResource<Texture> target,
  ) {
    if (_closed) return Future.error(StateError('Capture view has closed.'));
    if (_pending != null || _clearing != null) {
      return Future.error(StateError('One capture may be queued at a time.'));
    }
    final work = _capture(submission, target);
    _pending = work;
    return work.whenComplete(() => _pending = null);
  }

  Future<SceneCaptureReceipt> _capture(
    FrameSubmission submission,
    GpuResource<Texture> target,
  ) async {
    final descriptor = target.descriptor as TextureDescriptor;
    if (target.isClosed ||
        descriptor.format != TextureFormat.rgba16Float ||
        descriptor.dimension != TextureDimension.d2 ||
        descriptor.depth != 1 ||
        descriptor.width != submission.size.width ||
        descriptor.height != submission.size.height ||
        !descriptor.usage.containsAll({
          TextureUsage.sampled,
          TextureUsage.renderAttachment,
        }) ||
        submission.colorPipeline != null ||
        submission.temporalAA != null) {
      throw ArgumentError(
        'Capture requires a live matching linear RGBA16F attachment without display transforms or temporal effects.',
      );
    }
    final clock = Stopwatch()..start();
    final packet = _encoder.encode(submission);
    try {
      final reply = await target.submit(
        _device,
        (key) => _device.submitFrame(
          packet.submission,
          packet.bytes,
          (bytes) => _device._command(
            102,
            _ResourcePacket()
              ..u64(_encoder.viewId)
              ..key(key)
              ..data(bytes),
            responseBytes: 24,
          ),
          scenePacket: packet,
        ),
      );
      _encoder.accept(packet);
      final values = ByteData.sublistView(reply);
      return SceneCaptureReceipt(
        admission: packet.admission,
        drawCalls: values.getUint64(0, Endian.little),
        uploadedBytes: packet.uploadedBytes,
        attachmentBytes: values.getUint64(8, Endian.little),
        sharedEnergyLutBytes: values.getUint64(16, Endian.little),
        cpuSubmitTime: clock.elapsed,
      );
    } catch (_) {
      _encoder.reject(packet);
      rethrow;
    }
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    try {
      try {
        await _pending;
      } catch (_) {
        /* Drain failed work before releasing the view. */
      }
      await _clearing;
      await _device._command(101, _ResourcePacket()..u64(_encoder.viewId));
    } finally {
      _closedSignal.complete();
    }
  }
}
