part of 'native_renderer.dart';

/// Native rendering from a captured submission, without Flutter dependencies.
/// Apple surfaces use the same worker and GPU device as explicit capture.
class NativeBackend implements RenderBackend {
  final NativeRenderer _renderer;
  final bool _experimentalAppleSurfaces;
  bool _closed = false;
  Future<void>? _closing;
  int _nextFrame = 0;
  final _surfaces = <NativeSurfaceSnapshot>{};
  NativeBackend._(this._renderer, this._experimentalAppleSurfaces);

  /// Apple texture registration remains experimental while Flutter's texture
  /// cache prevents prompt buffer retirement. Keep it out of default selection.
  static Future<NativeBackend> create({
    bool experimentalAppleSurfaces = false,
  }) async {
    try {
      return NativeBackend._(
        await NativeRenderer.create(),
        experimentalAppleSurfaces,
      );
    } catch (error) {
      throw SceneException(
        SceneIssue(
          code: SceneIssueCodes.backendUnavailable,
          message: 'The native GPU renderer could not start.',
          operation: 'create',
          cause: error,
        ),
      );
    }
  }

  DeviceCapabilities get _capabilities => DeviceCapabilities(
    name: 'wgpu-native',
    features: {
      RenderFeature.indexedMeshes,
      RenderFeature.diffuseLighting,
      RenderFeature.unlitMaterials,
      RenderFeature.rgbaReadback,
      if (_experimentalAppleSurfaces && NativeSurfaces().appleAvailable)
        RenderFeature.sharedTexture,
    },
    limits: DeviceLimits(
      maxTextureDimension2D: 4096,
      maxGeometryBytes: 64 * 1024 * 1024,
    ),
  );
  @override
  DeviceCapabilities get capabilities => _capabilities;

  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    if (_closed) {
      throw SceneException(
        SceneIssue(
          code: SceneIssueCodes.disposed,
          message: 'The native backend has been closed.',
          operation: 'render',
        ),
      );
    }
    switch (submission.target) {
      case SurfaceTarget(:final surface):
        if (surface is! NativeSurfaceKey ||
            !capabilities.supports(RenderFeature.sharedTexture)) {
          throw SceneException(
            SceneIssue(
              code: SceneIssueCodes.presentationUnavailable,
              message: 'No native adapter owns this surface.',
              operation: 'render',
            ),
          );
        }
      case ReadbackTarget(:final format, :final colorSpace):
        if (format != PixelFormat.rgba8 || colorSpace != ColorSpace.srgb) {
          throw SceneException(
            SceneIssue(
              code: SceneIssueCodes.unsupportedFeature,
              message: 'Native readback currently supports RGBA8 sRGB only.',
              operation: 'render',
            ),
          );
        }
    }
    if (submission.size.width > capabilities.limits.maxTextureDimension2D ||
        submission.size.height > capabilities.limits.maxTextureDimension2D) {
      throw ArgumentError('Render dimensions exceed the backend limit.');
    }
    final clock = Stopwatch()..start();
    final packet = submission.toNativePacket(uploaded: _renderer._uploaded);
    var uploadedBytes = 0;
    for (final geometry in packet['geometries'] as List) {
      final data = geometry as Map;
      uploadedBytes +=
          (data['positions'] as List).length * 24 +
          (data['indices'] as List).length * 4;
    }
    try {
      if (submission.target case final SurfaceTarget target) {
        final pending = _renderer._renderSurfacePacket(
          packet,
          target,
          ++_nextFrame,
        );
        clock.stop();
        final receipt = await pending;
        return PresentedOutput(
          surface: target.surface,
          epoch: receipt[0],
          frameId: receipt[1],
          stats: FrameStats(
            frameId: receipt[1],
            surfaceEpoch: receipt[0],
            physicalSize: submission.size,
            presentationPath: PresentationPath.sharedTexture,
            cpuBuildTime: submission.cpuBuildTime,
            cpuSubmitTime: clock.elapsed,
            drawCalls: submission.scene.drawCalls,
            triangles: submission.scene.triangles,
            uploadedBytes: uploadedBytes,
            residentBytes: receipt[2],
            readbackBytes: receipt[3],
          ),
        );
      }
      final pending = _renderer._renderPacket(
        packet,
        submission.size.width,
        submission.size.height,
      );
      clock.stop();
      final frame = await pending;
      return ReadbackOutput(
        image: ImageData(pixels: frame.pixels, size: submission.size),
        stats: FrameStats(
          frameId: ++_nextFrame,
          physicalSize: submission.size,
          presentationPath: PresentationPath.readback,
          cpuBuildTime: submission.cpuBuildTime,
          cpuSubmitTime: clock.elapsed,
          drawCalls: submission.scene.drawCalls,
          triangles: submission.scene.triangles,
          uploadedBytes: uploadedBytes,
          readbackBytes: frame.pixels.length,
        ),
      );
    } on NativeSurfaceException catch (error) {
      throw SceneException(
        SceneIssue(
          code: [3, 6, 7, 14].contains(error.code)
              ? SceneIssueCodes.frameDeferred
              : SceneIssueCodes.renderFailed,
          message: error.message,
          operation: 'render',
          cause: error,
        ),
      );
    } on SceneException {
      rethrow;
    } on ArgumentError {
      rethrow;
    } catch (error) {
      throw SceneException(
        SceneIssue(
          code: SceneIssueCodes.renderFailed,
          message: 'The native frame could not be rendered.',
          operation: 'render',
          cause: error,
        ),
      );
    }
  }

  Future<NativeSurfaceSnapshot> openSurface(PhysicalSize size) async {
    if (_closed) throw StateError('Backend has closed.');
    if (!capabilities.supports(RenderFeature.sharedTexture)) {
      throw SceneException(
        SceneIssue(
          code: SceneIssueCodes.presentationUnavailable,
          message: 'This backend has no enabled shared surface adapter.',
          operation: 'openSurface',
        ),
      );
    }
    final native = NativeSurfaces();
    final surface = native.reserve(
      width: size.width,
      height: size.height,
      memoryLimit: 256 * 1024 * 1024,
    );
    _surfaces.add(surface);
    try {
      await _renderer._worker.request('surfaceAttach', [
        surface.key.toMessage(),
      ]);
      if (_closed) {
        throw StateError('Backend closed during surface attachment.');
      }
      return native.read(surface.key);
    } catch (_) {
      closeSurface(surface);
      rethrow;
    }
  }

  void closeSurface(NativeSurfaceSnapshot surface) {
    if (_surfaces.any((entry) => entry.key == surface.key)) {
      _surfaces.removeWhere((entry) => entry.key == surface.key);
      try {
        NativeSurfaces().close(surface);
      } on NativeSurfaceException catch (error) {
        if (error.code != 2) rethrow;
      }
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    Object? failure;
    StackTrace? failureStack;
    for (final surface in _surfaces.toList()) {
      try {
        closeSurface(surface);
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    await _renderer.dispose();
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }
}
