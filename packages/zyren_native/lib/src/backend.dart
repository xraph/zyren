part of 'native_renderer.dart';

/// Native rendering from a captured submission, without Flutter dependencies.
/// Apple surfaces use the same worker and GPU device as explicit capture.
class NativeBackend implements NativeGpuBackend {
  final NativeRenderer _renderer;
  Set<TextureFormat> _textureFormats = const {};
  late final ScenePacketEncoder _encoder;
  Future<FrameOutput>? _drawing;
  final bool _experimentalAppleSurfaces;
  bool _closed = false;
  Future<void>? _closing;
  int _nextFrame = 0;
  final _surfaces = <NativeSurfaceSnapshot>{};
  final _resourceScopes = <ResourceScope>{};
  final _shaderCompilers = <ShaderCompiler>{};
  final _graphCompilers = <GraphCompiler>{};
  final _materialCompilers = <MaterialCompiler>{};
  final _NativeResourceDevice _resources;
  NativeBackend._(
    this._renderer,
    this._experimentalAppleSurfaces, {
    int viewId = 1,
    _NativeResourceDevice? resources,
  }) : _resources =
           resources ??
           _NativeResourceDevice(_workerGpuSender(_renderer._worker)) {
    _encoder = ScenePacketEncoder(viewId: viewId, materialDevice: _resources);
  }

  /// An independent view that shares this device and its immutable geometry.
  /// Closing either view preserves the other view's scenes and resource scopes.
  NativeBackend createView() {
    if (_closed) throw StateError('Backend has closed.');
    if (_experimentalAppleSurfaces) {
      throw UnsupportedError(
        'Shared views currently support explicit readback only.',
      );
    }
    if (_renderer._owners >= 64) {
      throw StateError('Native device view limit reached.');
    }
    _renderer._owners++;
    return NativeBackend._(
      _renderer,
      false,
      viewId: ++_renderer._nextView,
      resources: _resources,
    ).._textureFormats = _textureFormats;
  }

  @override
  ResourceScope createResourceScope({String label = ''}) {
    if (_closed) throw StateError('Backend has closed.');
    final scope = ResourceScope(_resources, label: label);
    _resourceScopes.add(scope);
    scope.whenClosed.then((_) {
      _resourceScopes.remove(scope);
    });
    return scope;
  }

  @override
  Future<GpuInspection> inspectGpu({int allocationLimit = 128}) {
    if (_closed) throw StateError('Backend has closed.');
    return _resources.inspectGpu(allocationLimit: allocationLimit);
  }

  @override
  Future<ResourceStats> resourceStats() => _resources.stats();
  @override
  Future<void> configureResourceBudget(int bytes) {
    if (_closed) throw StateError('Backend has closed.');
    return _resources.configureBudget(bytes);
  }

  @override
  ShaderCompiler createShaderCompiler({String label = ''}) {
    if (_closed) throw StateError('Backend has closed.');
    final compiler = ShaderCompiler(_resources, label: label);
    _shaderCompilers.add(compiler);
    compiler.whenClosed.then((_) {
      _shaderCompilers.remove(compiler);
    });
    return compiler;
  }

  @override
  Future<ShaderStats> shaderStats() => _resources.shaderStats();

  @override
  GraphCompiler createGraphCompiler({String label = ''}) {
    if (_closed) throw StateError('Backend has closed.');
    final compiler = GraphCompiler(_resources, label: label);
    _graphCompilers.add(compiler);
    compiler.whenClosed.then((_) {
      _graphCompilers.remove(compiler);
    });
    return compiler;
  }

  @override
  MaterialCompiler createMaterialCompiler({String label = ''}) {
    if (_closed) throw StateError('Backend has closed.');
    final compiler = MaterialCompiler(_resources, label: label);
    _materialCompilers.add(compiler);
    compiler.whenClosed.then((_) => _materialCompilers.remove(compiler));
    return compiler;
  }

  @override
  Future<GraphCacheStats> graphStats() => _resources.graphStats();

  @override
  Future<TemporalStats> temporalStats() => _resources.temporalStats();

  @override
  Future<TransmissionStats> transmissionStats() =>
      _resources.transmissionStats();

  @override
  Future<ShadowStats> shadowStats() => _resources.shadowStats();

  /// Apple texture registration remains experimental while Flutter's texture
  /// cache prevents prompt buffer retirement. Keep it out of default selection.
  static Future<NativeBackend> create({
    bool experimentalAppleSurfaces = false,
  }) async {
    try {
      final backend = NativeBackend._(
        await NativeRenderer.create(),
        experimentalAppleSurfaces,
      );
      try {
        backend._textureFormats = await backend._resources.textureFormats();
        return backend;
      } catch (_) {
        await backend.close();
        rethrow;
      }
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
    backend: _renderer._deviceInfo.backend,
    adapterName: _renderer._deviceInfo.adapterName,
    textureFormats: _textureFormats,
    features: {
      RenderFeature.shaderMaterials,
      RenderFeature.postprocessing,
      RenderFeature.punctualLights,
      RenderFeature.shadowMaps,
      RenderFeature.spatialAntialiasing,
      RenderFeature.bloom,
      RenderFeature.sectionClipping,
      if (_renderer._deviceInfo.sampleCounts.contains(4))
        RenderFeature.multisampleAntialiasing,
      RenderFeature.floatTextures,
      RenderFeature.volumeTextures,
      RenderFeature.hdr,
      RenderFeature.reversedDepth,
      RenderFeature.selectionOutlines,
      RenderFeature.indexedMeshes,
      RenderFeature.diffuseLighting,
      RenderFeature.unlitMaterials,
      RenderFeature.rgbaReadback,
      RenderFeature.scopedResources,
      RenderFeature.colorTextures,
      RenderFeature.alphaMaterials,
      RenderFeature.portablePrimitives,
      RenderFeature.materialSidedness,
      RenderFeature.shaderCompilation,
      RenderFeature.renderGraphs,
      RenderFeature.frameGraphs,
      RenderFeature.meshShaders,
      RenderFeature.standardMaterials,
      RenderFeature.physicalMaterials,
      RenderFeature.areaLighting,
      RenderFeature.temporalAntialiasing,
      RenderFeature.hdrColor,
      RenderFeature.environmentLighting,
      RenderFeature.shadows,
      RenderFeature.instancing,
      RenderFeature.skinning,
      RenderFeature.morphTargets,
      RenderFeature.compute,
      RenderFeature.storageTextures,
      if (_experimentalAppleSurfaces && NativeSurfaces().appleAvailable)
        RenderFeature.sharedTexture,
    },
    limits: DeviceLimits(
      maxTextureDimension2D: 4096,
      maxTextureDimension3D: 256,
      sampleCounts: _renderer._deviceInfo.sampleCounts,
      maxResidentResourceBytes: _resources.resourceBudgetBytes,
      maxGeometryBytes: 64 * 1024 * 1024,
      maxInstances: 100000,
      maxJoints: 256,
      maxMorphTargets: 64,
      maxPunctualLights: 16,
      maxHemisphereLights: 4,
      maxAreaLights: 4,
    ),
  );
  @override
  DeviceCapabilities get capabilities => _capabilities;

  @override
  Future<FrameOutput> render(FrameSubmission submission) {
    if (_drawing != null) {
      return Future.error(
        StateError('Only one frame may be in flight per view.'),
      );
    }
    final future = _render(submission);
    _drawing = future;
    return future.whenComplete(() {
      _drawing = null;
    });
  }

  Future<FrameOutput> _render(FrameSubmission submission) async {
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
    try {
      if (submission.target case final SurfaceTarget target) {
        final packet = _encoder.encode(submission);
        final frameId = ++_nextFrame;
        final pending = _resources.submitFrame(
          submission,
          packet.bytes,
          (bytes) => _renderer._renderSurfacePacket(
            packet,
            _encoder,
            target,
            frameId,
            bytes: bytes,
          ),
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
            drawCalls:
                submission.scene.drawCalls +
                submission.scene.transmissionCaptureDraws +
                (submission.temporalAA == null
                    ? 0
                    : submission.scene.temporalMotionDraws + 1) +
                (submission.scene.usesScreenEffects
                    ? 0
                    : submission.scene.alphaResolveDraws) +
                submission.outputConversionDraws +
                (submission.graph?.drawCalls ?? 0),
            computeDispatches: submission.graph?.dispatches ?? 0,
            triangles:
                submission.scene.triangles +
                submission.scene.transmissionCaptureTriangles +
                (submission.temporalAA == null
                    ? 0
                    : submission.scene.triangles + 1) +
                (submission.scene.usesScreenEffects
                    ? 0
                    : submission.scene.alphaResolveDraws) +
                submission.outputConversionDraws +
                (submission.graph?.triangles ?? 0),
            uploadedBytes: packet.uploadedBytes,
            residentBytes: receipt[2],
            readbackBytes: receipt[3],
          ),
        );
      }
      final pending = _renderer._renderBinary(
        submission,
        _encoder,
        resources: _resources,
      );
      clock.stop();
      final frame = await pending;
      return ReadbackOutput(
        image: ImageData(
          pixels: frame.pixels,
          size: submission.size,
          alphaMode: submission.scene.usesScreenEffects
              ? AlphaMode.premultiplied
              : AlphaMode.straight,
        ),
        stats: FrameStats(
          frameId: ++_nextFrame,
          physicalSize: submission.size,
          presentationPath: PresentationPath.readback,
          cpuBuildTime: submission.cpuBuildTime,
          cpuSubmitTime: clock.elapsed,
          drawCalls:
              submission.scene.drawCalls +
              submission.scene.transmissionCaptureDraws +
              (submission.temporalAA == null
                  ? 0
                  : submission.scene.temporalMotionDraws + 1) +
              (submission.scene.usesScreenEffects
                  ? 0
                  : submission.scene.alphaResolveDraws) +
              submission.outputConversionDraws +
              (submission.graph?.drawCalls ?? 0),
          computeDispatches: submission.graph?.dispatches ?? 0,
          triangles:
              submission.scene.triangles +
              submission.scene.transmissionCaptureTriangles +
              (submission.temporalAA == null
                  ? 0
                  : submission.scene.triangles + 1) +
              (submission.scene.usesScreenEffects
                  ? 0
                  : submission.scene.alphaResolveDraws) +
              submission.outputConversionDraws +
              (submission.graph?.triangles ?? 0),
          uploadedBytes: frame.uploadedBytes,
          residentBytes: frame.residentBytes,
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
    final resourceClosures = [
      for (final close in [
        for (final c in _materialCompilers.toList()) c.close,
        for (final c in _graphCompilers.toList()) c.close,
      ])
        close().then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            failure ??= error;
            failureStack ??= stack;
          },
        ),
      for (final compiler in _shaderCompilers.toList())
        compiler.close().then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            failure ??= error;
            failureStack ??= stack;
          },
        ),
      for (final scope in _resourceScopes.toList())
        scope.close().then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            failure ??= error;
            failureStack ??= stack;
          },
        ),
    ];
    for (final surface in _surfaces.toList()) {
      try {
        closeSurface(surface);
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    await Future.wait(resourceClosures);
    try {
      await _drawing;
    } catch (_) {
      /* The native owner still needs cleanup. */
    }
    await _renderer._releaseView(_encoder.viewId);
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  }
}
