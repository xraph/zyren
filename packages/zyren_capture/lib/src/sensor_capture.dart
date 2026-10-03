part of '../sensors.dart';

final class SensorCaptureCancelled implements Exception {
  final String requestId;
  const SensorCaptureCancelled(this.requestId);
}

/// Captures mutable scene and camera state synchronously at construction.
final class SensorCaptureRequest {
  final String id;
  final int tick, sceneRevision;
  final double? near, far;
  final FrameSubmission submission;
  SensorCaptureRequest({
    required this.id,
    required this.tick,
    required Scene scene,
    required Camera camera,
    required PhysicalSize size,
    bool depth = false,
    FrameTime time = const FrameTime(),
  }) : near = camera is PerspectiveCamera
           ? camera.near
           : camera is OrthographicCamera
           ? camera.near
           : null,
       far = camera is PerspectiveCamera
           ? camera.far
           : camera is OrthographicCamera
           ? camera.far
           : null,
       sceneRevision = scene.revision,
       submission = _capture(id, tick, scene, camera, size, depth, time);
  static FrameSubmission _capture(
    String id,
    int tick,
    Scene scene,
    Camera camera,
    PhysicalSize size,
    bool depth,
    FrameTime time,
  ) {
    if (id.isEmpty ||
        id.length > 128 ||
        tick < 0 ||
        size.width > 4096 ||
        size.height > 4096) {
      throw ArgumentError('Invalid sensor capture request.');
    }
    return FrameSubmission.capture(
      scene: scene,
      camera: camera,
      size: size,
      time: time,
      target: ReadbackTarget(depth: depth),
    );
  }

  bool get wantsDepth => (submission.target as ReadbackTarget).depth;
  int get bufferBytes =>
      submission.size.width * submission.size.height * (wantsDepth ? 9 : 4);
}

/// Buffers are owned by this immutable receipt, independent of pooled targets.
/// Depth is camera-axis metres; its separate mask marks background/invalid.
final class SensorCaptureReceipt {
  final String requestId;
  final int tick, frameId, resourceGeneration, sceneRevision;
  final CameraSnapshot camera;
  final double? near, far;
  final ImageData image;
  final DepthData? depth;
  final FrameStats stats;
  final Duration elapsed;
  SensorCaptureReceipt._(
    SensorCaptureRequest request,
    ReadbackOutput output,
    this.resourceGeneration,
    Stopwatch clock,
  ) : requestId = request.id,
      tick = request.tick,
      frameId = output.stats.frameId,
      near = request.near,
      far = request.far,
      sceneRevision = request.sceneRevision,
      camera = request.submission.camera,
      image = _copySensorImage(output.image),
      depth = _copySensorDepth(output.depth),
      stats = output.stats,
      elapsed = clock.elapsed;
  int get width => image.size.width;
  int get height => image.size.height;
  ColorSpace get colorSpace => image.colorSpace;
  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'tick': tick,
    'frameId': frameId,
    'sceneRevision': sceneRevision,
    'resourceGeneration': resourceGeneration,
    'width': width,
    'height': height,
    'pixelFormat': image.format.name,
    'colorSpace': colorSpace.name,
    'alphaMode': image.alphaMode.name,
    'rows': 'top-down',
    'depth': depth == null ? null : 'camera-axis-metres',
    'invalidDepth': depth == null ? null : 'zero-with-separate-validity-mask',
    'depthCoverage': 'depth-writing-fragments; nearest-covered-MSAA-sample',
    'near': near,
    'far': far,
    'depthStrategy': camera.depthStrategy.name,
    'projection': camera.projection,
    'viewProjection': camera.viewProjection,
    'origin': camera.origin,
    'forward': camera.forward,
    'bufferLifetime': 'receipt-owned',
    'elapsedMicros': elapsed.inMicroseconds,
    'gpuMicros': stats.gpuTime?.inMicroseconds,
  };
}

/// Owns one persistent backend. Native targets reuse allocations at equal sizes;
/// resize replaces them only after the preceding GPU submission has finished.
/// Queue and requested output bytes stay reserved until actual render completion.
final class SensorCapturePool {
  final Future<RenderBackend> Function() openBackend;
  final int maxPending, maxBytes;
  Future<RenderBackend>? _backend;
  Future<void> _tail = Future.value();
  Future<void>? _closing, _recreation;
  final Map<String, bool> _pending = {};
  bool _closed = false, _resetting = false;
  int _bytes = 0, _generation = 0;
  SensorCapturePool({
    required this.openBackend,
    this.maxPending = 8,
    this.maxBytes = 64 * 1024 * 1024,
  }) {
    if (maxPending < 1 ||
        maxPending > 64 ||
        maxBytes < 4 ||
        maxBytes > 256 * 1024 * 1024) {
      throw ArgumentError('Invalid sensor pool bounds.');
    }
  }
  int get pendingCount => _pending.length;
  int get reservedBytes => _bytes;
  bool get isClosed => _closed;
  Future<SensorCaptureReceipt> capture(SensorCaptureRequest request) {
    if (_closed ||
        _resetting ||
        _pending.containsKey(request.id) ||
        _pending.length >= maxPending ||
        request.bufferBytes > maxBytes - _bytes) {
      return Future.error(StateError('Sensor capture pool closed or full.'));
    }
    _pending[request.id] = false;
    _bytes += request.bufferBytes;
    final result = _tail.then((_) async {
      void check() {
        if (_pending[request.id] == true) {
          throw SensorCaptureCancelled(request.id);
        }
      }

      try {
        check();
        final backend = await (_backend ??= openBackend());
        check();
        if (!backend.capabilities.supports(RenderFeature.rgbaReadback) ||
            request.wantsDepth &&
                !backend.capabilities.supports(
                  RenderFeature.metricDepthReadback,
                )) {
          throw UnsupportedError('Requested sensor attachment is unsupported.');
        }
        final clock = Stopwatch()..start();
        final output = await backend.render(request.submission);
        check();
        final size = request.submission.size;
        if (output is! ReadbackOutput ||
            output.image.size.width != size.width ||
            output.image.size.height != size.height ||
            output.image.format != PixelFormat.rgba8 ||
            output.image.colorSpace != ColorSpace.srgb ||
            request.wantsDepth &&
                (output.depth == null ||
                    output.depth!.size.width != size.width ||
                    output.depth!.size.height != size.height) ||
            output.stats.admission?.candidateReady == false) {
          throw StateError(
            'Sensor output does not match the captured request.',
          );
        }
        return SensorCaptureReceipt._(request, output, _generation, clock);
      } finally {
        _pending.remove(request.id);
        _bytes -= request.bufferBytes;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void cancel(String id) {
    if (_pending.containsKey(id)) _pending[id] = true;
  }

  Future<void> recreate() => _recreation ??= _recreate().whenComplete(() {
    _recreation = null;
  });
  Future<void> _recreate() async {
    if (_closed || _resetting) throw StateError('Sensor pool cannot recreate.');
    _resetting = true;
    for (final id in _pending.keys.toList()) {
      cancel(id);
    }
    try {
      await _tail;
      await _closeBackend();
      _generation++;
    } finally {
      _resetting = false;
    }
  }

  Future<void> _closeBackend() async {
    final opening = _backend;
    _backend = null;
    if (opening == null) return;
    final RenderBackend backend;
    try {
      backend = await opening;
    } catch (_) {
      return;
    }
    await backend.close();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    for (final id in _pending.keys.toList()) {
      cancel(id);
    }
    await _recreation;
    await _tail;
    await _closeBackend();
  }
}

ImageData _copySensorImage(ImageData image) {
  final row = image.size.width * 4;
  final pixels = Uint8List(row * image.size.height);
  for (var y = 0; y < image.size.height; y++) {
    pixels.setRange(y * row, (y + 1) * row, image.pixels, y * image.rowStride);
  }
  return ImageData(
    pixels: pixels,
    size: image.size,
    format: image.format,
    colorSpace: image.colorSpace,
    alphaMode: image.alphaMode,
  );
}

DepthData? _copySensorDepth(DepthData? depth) => depth == null
    ? null
    : DepthData(
        size: depth.size,
        metres: Float32List.fromList(depth.metres),
        validity: Uint8List.fromList(depth.validity),
      );
