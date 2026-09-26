part of 'native_renderer.dart';

/// Native rendering from a captured submission, without Flutter dependencies.
/// Shared surfaces are rejected until a platform adapter is registered.
class NativeBackend implements RenderBackend {
  final NativeRenderer _renderer;
  bool _closed = false;
  int _nextFrame = 0;
  NativeBackend._(this._renderer);

  static Future<NativeBackend> create() async {
    try {
      return NativeBackend._(await NativeRenderer.create());
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

  static final _capabilities = DeviceCapabilities(
    name: 'wgpu-native',
    features: {
      RenderFeature.indexedMeshes,
      RenderFeature.diffuseLighting,
      RenderFeature.unlitMaterials,
      RenderFeature.rgbaReadback,
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
      case SurfaceTarget():
        throw SceneException(
          SceneIssue(
            code: SceneIssueCodes.presentationUnavailable,
            message: 'This backend has no shared-texture presentation adapter.',
            operation: 'render',
          ),
        );
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
          frameId: _nextFrame++,
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

  @override
  Future<void> close() {
    _closed = true;
    return _renderer.dispose();
  }
}
