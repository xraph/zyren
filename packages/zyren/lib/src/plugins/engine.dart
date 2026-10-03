import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import '../resources/buffer.dart';
import '../resources/gpu_scope.dart';
import 'registration.dart';
import '../rendering/gpu_diagnostics.dart';
import 'attachment_scope.dart';
import '../input/pointer_event.dart';
import '../rendering/capabilities.dart';
import '../rendering/depth_strategy.dart';
import '../rendering/color_pipeline.dart';
import '../rendering/temporal_aa_options.dart';
import '../rendering/scene_issue.dart';
import '../rendering/renderer.dart';
import '../rendering/frame_submission.dart';
import '../rendering/frame_output.dart';
import '../rendering/render_backend.dart';
import '../scene/scene.dart';
import '../scene/layer_mask.dart';
import '../resources/resource_scope.dart';
import '../resources/texture.dart';
part 'plugin_graph.dart';
part 'plugin_updates.dart';
part 'texture_history.dart';
part 'environment_binding.dart';
part 'temporal_binding.dart';

/// Share one exported key instance between a provider and its dependents.
class ServiceKey<T extends Object> {
  final String name;
  const ServiceKey(this.name);
  @override
  String toString() => name;
}

class FrameInfo {
  final Duration elapsed, delta;
  final int number, width, height;
  const FrameInfo({
    required this.elapsed,
    required this.delta,
    required this.number,
    required this.width,
    required this.height,
  });
}

/// Hooks execute in dependency order. Detachment runs in reverse order.
/// Keep plugin instances stable across widget builds and use one per viewport.
abstract class ScenePlugin {
  String get id;
  Set<String> get dependencies => const {};
  Set<RenderFeature> get requiredFeatures => const {};

  /// Validate the complete, dependency-ordered configuration without side effects.
  /// Runs before backend creation or any live attachment is removed.
  void validateComposition(List<ScenePlugin> plugins) {}

  FutureOr<void> attach(PluginContext context) {}
  FutureOr<void> beforeRender(PluginContext context, FrameInfo frame) {}
  FutureOr<void> afterRender(
    PluginContext context,
    FrameInfo info,
    FrameStats stats,
  ) {}

  /// Also called after a failed attach, so tolerate partial initialization.
  FutureOr<void> detach(PluginContext context) {}
}

/// One attachment selects the final frame graph for its view. Assign a compiled
/// replacement in beforeRender after compilation succeeds. A null value disables
/// effects. The graph's compiler continues to own its resources and lifetime.
final class FrameGraphBinding {
  CompiledGraph? _graph;
  bool _closed = false;
  FrameGraphBinding._();
  CompiledGraph? get graph => _graph;
  set graph(CompiledGraph? value) {
    if (_closed) throw StateError('Frame graph binding has closed.');
    if (value != null && (!value.isFrameGraph || value.isClosed)) {
      throw ArgumentError('Select a live compiled scene frame graph.');
    }
    _graph = value;
  }

  void _close() {
    _closed = true;
    _graph = null;
  }
}

/// Services belong to this engine, never to a process-wide registry.
class PluginContext {
  final String _pluginId;
  final RenderBackend? _backend;
  ShaderCompiler? _shaders;
  MaterialCompiler? _materials;
  ResourceScope? _resources;
  GraphCompiler? _graphs;

  FrameGraphBinding? _frameGraph;
  EnvironmentBinding? _environment;
  final EnvironmentBinding Function() _claimEnvironment;
  TemporalBinding? _temporal;
  final TemporalBinding Function() _claimTemporal;
  PluginGraph? _graph;
  final _SharedFrameGraph Function() _claimGraph;
  final FrameGraphBinding Function() _claimFrameGraph;
  final Scene scene;
  Camera camera;
  final DeviceCapabilities capabilities;
  final InputSource? input;
  final scope = AttachmentScope();
  final Map<Object, Object> _services;
  final void Function()? _invalidate;
  final Registration Function()? _demand;
  final Set<Object> _provided = {};
  bool _registering = true;
  bool _active = true;
  PluginContext._(
    this._pluginId,
    this._backend,
    this.scene,
    this.camera,
    this.capabilities,
    this._services,
    this._invalidate,
    this._demand,
    this.input,
    this._claimFrameGraph,
    this._claimGraph,
    this._claimEnvironment,
    this._claimTemporal,
  );

  /// Whether this call is inside an active beforeRender hook for this engine
  /// and this exact frame. Async work loses permission when its hook returns.
  bool isPreparingFrame(FrameInfo frame) {
    final preparation = Zone.current[SceneEngine._preparationZone];
    return preparation is _FramePreparation &&
        preparation.active &&
        identical(preparation.services, _services) &&
        identical(preparation.frame, frame);
  }

  /// Queries the backend only when you request an inspection.
  Future<GpuInspection?> inspectGpu({int allocationLimit = 128}) async {
    if (!_active || scope.isClosed) {
      throw StateError('Plugin context has been detached.');
    }
    if (allocationLimit < 1 || allocationLimit > 256) {
      throw RangeError.range(allocationLimit, 1, 256, 'allocationLimit');
    }
    final backend = _backend;
    return backend is GpuDiagnosticsBackend
        ? (backend as GpuDiagnosticsBackend).inspectGpu(
            allocationLimit: allocationLimit,
          )
        : null;
  }

  /// Shared preparation and effect contributions, owned by this attachment.
  PluginGraph get graph {
    _checkAttached();
    if (_graph case final graph?) return graph;
    if (!_registering) {
      throw StateError('Claim shared graph access during attach.');
    }
    for (final feature in const [
      RenderFeature.scopedResources,
      RenderFeature.shaderCompilation,
      RenderFeature.renderGraphs,
      RenderFeature.frameGraphs,
    ]) {
      if (!capabilities.supports(feature) ||
          (feature == RenderFeature.renderGraphs &&
              _backend is! GraphBackend)) {
        throw _unsupported(
          feature,
          'attach',
          'This backend cannot compose shared frame graphs.',
        );
      }
    }
    return _graph = PluginGraph._(this, _claimGraph());
  }

  /// Claim during attach, then select compiled replacements in beforeRender.
  /// Only one plugin owns final composition; providers can share pass builders
  /// with other plugins through a typed service.
  FrameGraphBinding get frameGraph {
    _checkAttached();
    if (_frameGraph case final binding?) return binding;
    if (!_registering) {
      throw StateError('Claim frame composition during attach.');
    }
    if (!capabilities.supports(RenderFeature.frameGraphs)) {
      throw _unsupported(
        RenderFeature.frameGraphs,
        'attach',
        'This backend cannot compose scene frame graphs.',
      );
    }
    final binding = _claimFrameGraph();
    scope.keep(Registration(binding._close));
    return _frameGraph = binding;
  }

  /// Lazily owns GPU allocations for this attachment on its backend's device.
  ResourceScope get resources {
    _checkAttached();
    if (_resources case final resources?) return resources;
    final backend = _backend;
    if (backend is! ResourceBackend) {
      throw _unsupported(
        RenderFeature.scopedResources,
        'allocate',
        'This backend cannot allocate scoped GPU resources.',
      );
    }
    final resources = backend.createResourceScope(label: _pluginId);
    scope.onClose(resources.close);
    return _resources = resources;
  }

  /// Owns one explicitly executed graph per attachment. Failed candidates keep
  /// the active graph; closing [scope] drains executions and releases ownership.
  GraphCompiler get graphs {
    _checkAttached();
    if (_graphs case final compiler?) return compiler;
    final backend = _backend;
    if (backend is! GraphBackend) {
      throw _unsupported(
        RenderFeature.renderGraphs,
        'compile',
        'This backend cannot compile custom render graphs.',
      );
    }
    final compiler = backend.createGraphCompiler(label: _pluginId);
    scope.onClose(compiler.close);
    return _graphs = compiler;
  }

  /// Lazily owns shader programs for this attachment. Closing [scope] stops
  /// compilation and releases its programs after accepted work settles.
  ShaderCompiler get shaders {
    _checkAttached();
    if (_shaders case final compiler?) return compiler;
    final backend = _backend;
    if (backend is! ShaderBackend) {
      throw _unsupported(
        RenderFeature.shaderCompilation,
        'compile',
        'This backend cannot compile custom shaders.',
      );
    }
    final compiler = backend.createShaderCompiler(label: _pluginId);
    scope.onClose(compiler.close);
    return _shaders = compiler;
  }

  GpuScope createGpuScope({String label = ''}) {
    _checkAttached();
    final backend = _backend;
    if (backend is! MaterialBackend) {
      throw _unsupported(
        RenderFeature.shaderMaterials,
        'allocate',
        'This backend cannot allocate a GPU scope.',
      );
    }
    final result = GpuScope.fromBackend(
      backend,
      label: label.isEmpty ? _pluginId : label,
    );
    scope.onClose(result.close);
    return result;
  }

  MaterialCompiler get materials {
    _checkAttached();
    if (_materials case final compiler?) return compiler;
    final backend = _backend;
    if (backend is! MaterialBackend) {
      throw _unsupported(
        RenderFeature.shaderMaterials,
        'compile',
        'This backend cannot compile mesh materials.',
      );
    }
    final compiler = backend.createMaterialCompiler(label: _pluginId);
    scope.onClose(compiler.close);
    return _materials = compiler;
  }

  void _checkAttached() {
    if (!_active || scope.isClosed) {
      throw StateError('Plugin context has been detached.');
    }
  }

  SceneException _unsupported(
    RenderFeature feature,
    String operation,
    String message,
  ) => SceneException(
    SceneIssue(
      code: SceneIssueCodes.unsupportedFeature,
      message: message,
      operation: operation,
      pluginId: _pluginId,
      requiredFeatures: {feature},
      limits: capabilities.limits,
    ),
  );

  void invalidate() {
    if (!_active) throw StateError('Plugin context has been detached.');
    _invalidate?.call();
  }

  Registration acquireFrameDemand() {
    if (!_active) throw StateError('Plugin context has been detached.');
    return scope.keep(_demand?.call() ?? Registration(() {}));
  }

  void provide<T extends Object>(ServiceKey<T> key, T service) {
    if (!_active || !_registering || scope.isClosed) {
      throw StateError('Register services during attach.');
    }
    if (_services.containsKey(key)) {
      throw StateError('Service $key already has a provider.');
    }
    _services[key] = service;
    _provided.add(key);
  }

  T service<T extends Object>(ServiceKey<T> key) {
    if (!_active) throw StateError('Plugin context has been detached.');
    final value = _services[key];
    if (value == null) throw StateError('Service $key has no provider.');
    return value as T;
  }

  void _close() {
    for (final key in _provided) {
      _services.remove(key);
    }
    _active = false;
  }
}

class EngineCleanupException implements Exception {
  final List<Object> errors;
  EngineCleanupException(Iterable<Object> errors)
    : errors = List.unmodifiable(errors);
  @override
  String toString() => 'Engine cleanup failed: ${errors.join('; ')}';
}

class EngineInitializationException implements Exception {
  final Object cause, cleanupError;
  EngineInitializationException(this.cause, this.cleanupError);
  @override
  String toString() => 'Engine initialization failed: $cause ($cleanupError)';
}

/// Owns one renderer and a reconciled plugin configuration, with no widget state.
class SceneEngine {
  static final _owners = Expando<Object>('ScenePlugin owner');

  /// True inside an attach, render or detach hook, including its async work.
  /// Adapters can reject queued lifecycle changes before waiting on a hook.
  static bool get inPluginHook => Zone.current[_hookZone] != null;
  final Scene scene;
  Camera _camera;
  Camera get camera => _camera;
  set camera(Camera value) {
    if (_closed) throw StateError('Engine has been disposed.');
    if (identical(_camera, value)) return;
    _camera = value;
    invalidateHistory();
    for (final (_, context) in _attached) {
      context.camera = value;
    }
  }

  /// Call after a discontinuous camera move or another temporal discontinuity.
  void invalidateHistory() {
    if (_closed) throw StateError('Engine has been disposed.');
    _sharedGraph?.invalidateHistory();
    if (_temporal?._closed == false) _temporal!.reset();
  }

  EnvironmentBinding? _environment;
  TemporalBinding? _temporal;
  TemporalBinding _claimTemporal(String pluginId) {
    if (_temporal != null && !_temporal!._closed) {
      throw StateError(
        'Plugin $pluginId cannot replace the temporal provider.',
      );
    }
    return _temporal = TemporalBinding._();
  }

  EnvironmentBinding _claimEnvironment(String pluginId) {
    if (_environment != null && !_environment!._closed) {
      throw StateError(
        'Plugin $pluginId cannot replace the environment provider.',
      );
    }
    return _environment = EnvironmentBinding._();
  }

  FrameGraphBinding? _frameGraph;
  String? _frameGraphOwner;
  _SharedFrameGraph? _sharedGraph;
  _SharedFrameGraph _claimGraph() {
    if (_frameGraph != null && !_frameGraph!._closed) {
      throw StateError(
        'Manual frame composition already belongs to $_frameGraphOwner.',
      );
    }
    return _sharedGraph ??= _SharedFrameGraph(
      _backend! as GraphBackend,
      _onIssue,
    );
  }

  FrameGraphBinding _claimFrameGraph(String pluginId) {
    if ((_frameGraph != null && !_frameGraph!._closed) ||
        _sharedGraph != null) {
      throw StateError(
        'Frame composition already belongs to ${_frameGraphOwner ?? 'shared graph plugins'}.',
      );
    }
    _frameGraphOwner = pluginId;
    return _frameGraph = FrameGraphBinding._();
  }

  final SceneRenderer? _renderer;
  final RenderBackend? _backend;
  List<ScenePlugin> _plugins;
  final InputSource? _input;
  final void Function()? _onInvalidate;
  final Registration Function()? _acquireFrameDemand;
  Future<void> _pluginUpdates = Future.value();
  int _pendingPluginUpdates = 0;
  static final _hookZone = Object();
  static final _preparationZone = Object();
  final Object _owner;
  final void Function(SceneIssue)? _onIssue;
  final Map<Object, Object> _services = {};
  final List<(ScenePlugin, PluginContext)> _attached = [];
  Future<FrameOutput>? _frame;
  FrameSource? _publishedSource;
  Future<void>? _disposal;
  Registration? _cancellation;
  Duration? _lastElapsed;
  int _frameNumber = 0;
  bool _closed = false;

  SceneEngine._(
    this.scene,
    this._camera,
    this._renderer,
    this._backend,
    this._plugins,
    this._owner,
    this._onIssue,
    this._input,
    this._onInvalidate,
    this._acquireFrameDemand,
  );
  DeviceCapabilities get capabilities =>
      _backend?.capabilities ?? _renderer!.capabilities;
  List<String> get pluginIds => List.unmodifiable(_plugins.map((p) => p.id));

  static Future<SceneEngine> create({
    required Scene scene,
    required Camera camera,
    RendererFactory? rendererFactory,
    Future<RenderBackend> Function()? backendFactory,
    List<ScenePlugin> plugins = const [],
    InputSource? input,
    AttachmentScope? lifetime,
    void Function()? onInvalidate,
    void Function(SceneIssue)? onIssue,
    Registration Function()? acquireFrameDemand,
  }) async {
    if ((rendererFactory == null) == (backendFactory == null)) {
      throw ArgumentError(
        'Provide exactly one rendererFactory or backendFactory.',
      );
    }
    if (lifetime?.isClosed ?? false) throw _cancelled();
    final ordered = _resolve(plugins);
    for (final plugin in ordered) {
      if (_owners[plugin] != null) {
        throw StateError(
          'Plugin ${plugin.id} is already attached to an engine.',
        );
      }
    }
    final owner = Object();
    for (final plugin in ordered) {
      _owners[plugin] = owner;
    }
    SceneEngine? engine;
    var cancelled = false;
    var attaching = false;
    var acceptCancellation = true;
    var initialized = false;
    Registration? cancellation;
    try {
      cancellation = lifetime?.keep(
        Registration(() {
          if (!acceptCancellation || (engine?._closed ?? false)) return;
          cancelled = true;
          final errors = <Object>[];
          for (final (_, context)
              in engine?._attached.reversed ??
                  <(ScenePlugin, PluginContext)>[]) {
            try {
              context.scope.close();
            } catch (error) {
              errors.add(error);
            }
          }
          if (initialized) {
            // Lifetime close stops new submissions now. Callers can await the
            // same disposal future to observe asynchronous cleanup failures.
            engine!.dispose().then<void>(
              (_) {},
              onError: (Object _, StackTrace _) {},
            );
          }
          if (errors.isNotEmpty) throw ScopeCleanupException(errors);
        }),
      );
      final renderer = await rendererFactory?.call();
      final backend = await backendFactory?.call();
      engine = SceneEngine._(
        scene,
        camera,
        renderer,
        backend,
        ordered,
        owner,
        onIssue,
        input,
        onInvalidate,
        acquireFrameDemand,
      );
      if (cancelled) throw _cancelled();
      for (final plugin in ordered) {
        final missing = plugin.requiredFeatures.difference(
          engine.capabilities.features,
        );
        if (missing.isNotEmpty) {
          throw SceneException(
            SceneIssue(
              code: SceneIssueCodes.unsupportedFeature,
              operation: 'attach',
              pluginId: plugin.id,
              requiredFeatures: Set.unmodifiable(missing),
              limits: engine.capabilities.limits,
              message:
                  'Plugin ${plugin.id} requires unsupported features: ${missing.map((feature) => feature.name).join(', ')}.',
            ),
          );
        }
      }
      for (final plugin in ordered) {
        final context = PluginContext._(
          plugin.id,
          backend,
          scene,
          camera,
          engine.capabilities,
          engine._services,
          onInvalidate,
          acquireFrameDemand,
          input,
          () => engine!._claimFrameGraph(plugin.id),
          () => engine!._claimGraph(),
          () => engine!._claimEnvironment(plugin.id),
          () => engine!._claimTemporal(plugin.id),
        );
        engine._attached.add((plugin, context));
        try {
          attaching = true;
          await engine._hook(() => plugin.attach(context));
          if (cancelled) throw _cancelled();
        } finally {
          context._registering = false;
        }
      }
      engine._cancellation = cancellation;
      initialized = true;
      return engine;
    } catch (error, stack) {
      acceptCancellation = false;
      cancellation?.dispose();
      try {
        await engine?.dispose();
      } catch (cleanupError) {
        throw EngineInitializationException(error, cleanupError);
      } finally {
        for (final plugin in ordered) {
          if (identical(_owners[plugin], owner)) _owners[plugin] = null;
        }
      }
      if (cancelled && attaching) throw _cancelled(error);
      Error.throwWithStackTrace(error, stack);
    }
  }

  static List<ScenePlugin> _resolve(List<ScenePlugin> plugins) {
    final byId = <String, ScenePlugin>{};
    for (final plugin in plugins) {
      if (plugin.id.trim().isEmpty || byId.containsKey(plugin.id)) {
        throw ArgumentError(
          'Plugin IDs must be nonempty and unique: ${plugin.id}.',
        );
      }
      byId[plugin.id] = plugin;
    }
    final visiting = <String>{}, visited = <String>{};
    final ordered = <ScenePlugin>[];
    void visit(String id) {
      if (visited.contains(id)) return;
      final plugin = byId[id];
      if (plugin == null) {
        throw SceneException(
          SceneIssue(
            code: SceneIssueCodes.pluginDependencyMissing,
            operation: 'compose',
            pluginId: id,
            message: 'Missing plugin dependency: $id.',
          ),
        );
      }
      if (!visiting.add(id)) {
        throw SceneException(
          SceneIssue(
            code: SceneIssueCodes.pluginDependencyCycle,
            operation: 'compose',
            pluginId: id,
            message: 'Plugin dependency cycle at $id.',
          ),
        );
      }
      for (final dependency in plugin.dependencies) {
        visit(dependency);
      }
      visiting.remove(id);
      visited.add(id);
      ordered.add(plugin);
    }

    for (final id in byId.keys) {
      visit(id);
    }
    final resolved = List<ScenePlugin>.unmodifiable(ordered);
    for (final plugin in resolved) {
      plugin.validateComposition(resolved);
    }
    return resolved;
  }

  /// Explicit readback compatibility entry point. Use [renderFrame] for surfaces.
  Future<RenderedFrame> render({
    required Duration elapsed,
    FrameTime? time,
    required int width,
    required int height,
  }) async {
    final output = await renderFrame(
      elapsed: elapsed,
      time: time,
      width: width,
      height: height,
    );
    if (output is! ReadbackOutput) {
      throw StateError('Readback rendering requires an image output.');
    }
    return RenderedFrame.fromImage(output.image);
  }

  Future<FrameOutput> renderFrame({
    double? aspectRatio,
    ColorPipeline? colorPipeline,
    CompiledGraph? graph,
    OutputTarget target = const ReadbackTarget(),
    required Duration elapsed,
    FrameTime? time,
    required int width,
    required int height,
  }) {
    if (_closed) return Future.error(StateError('Engine has been disposed.'));
    if (_pendingPluginUpdates > 0) {
      return Future.error(
        SceneException(
          SceneIssue(
            code: SceneIssueCodes.frameDeferred,
            message: 'Plugin reconciliation is pending. Retry the frame.',
            operation: 'render',
          ),
        ),
      );
    }
    if (colorPipeline != null &&
        !capabilities.supports(RenderFeature.hdrColor)) {
      return Future.error(
        SceneException(
          SceneIssue(
            code: SceneIssueCodes.unsupportedFeature,
            message: "This backend does not support HDR color.",
            operation: "render",
            requiredFeatures: {RenderFeature.hdrColor},
          ),
        ),
      );
    }
    if (!capabilities.limits.sampleCounts.contains(
      colorPipeline?.sampleCount ?? 1,
    )) {
      return Future.error(
        SceneException(
          SceneIssue(
            code: SceneIssueCodes.unsupportedFeature,
            message: 'The requested sample count exceeds this backend profile.',
            operation: 'render',
            limits: capabilities.limits,
          ),
        ),
      );
    }
    if (graph != null && _sharedGraph != null) {
      return Future.error(
        StateError(
          'Explicit frame graphs cannot override shared plugin composition.',
        ),
      );
    }
    if (graph != null && !capabilities.supports(RenderFeature.frameGraphs)) {
      return Future.error(
        SceneException(
          SceneIssue(
            code: SceneIssueCodes.unsupportedFeature,
            message: 'This backend does not support scene frame graphs.',
            operation: 'render',
          ),
        ),
      );
    }
    if (_frame != null) {
      return Future.error(StateError('Only one frame may be in flight.'));
    }
    if (elapsed.isNegative ||
        width < 1 ||
        height < 1 ||
        width > capabilities.limits.maxTextureDimension2D ||
        height > capabilities.limits.maxTextureDimension2D) {
      return Future.error(ArgumentError('Invalid frame time or dimensions.'));
    }
    final last = _lastElapsed;
    final delta = last == null || elapsed < last
        ? Duration.zero
        : Duration(
            microseconds: (elapsed - last).inMicroseconds.clamp(0, 100000),
          );
    final info = FrameInfo(
      elapsed: elapsed,
      delta: time?.delta ?? delta,
      number: _frameNumber++,
      width: width,
      height: height,
    );
    _lastElapsed = elapsed;
    final future = Future<FrameOutput>.microtask(() async {
      for (final (plugin, context) in _attached) {
        final preparation = _FramePreparation(context._services, info);
        try {
          await runZoned(
            () => _hook(() => plugin.beforeRender(context, info)),
            zoneValues: {_preparationZone: preparation},
          );
        } finally {
          preparation.active = false;
        }
      }
      if (camera.depthStrategy == DepthStrategy.reversed &&
          !capabilities.supports(RenderFeature.reversedDepth)) {
        throw SceneException(
          SceneIssue(
            code: SceneIssueCodes.unsupportedFeature,
            message: 'This backend does not support reversed depth.',
            operation: 'render',
            requiredFeatures: {RenderFeature.reversedDepth},
          ),
        );
      }
      if (scene.outline case final outline?) {
        if (outline.objects.isNotEmpty &&
            outline.opacity > 0 &&
            !capabilities.supports(RenderFeature.selectionOutlines)) {
          throw SceneException(
            SceneIssue(
              code: SceneIssueCodes.unsupportedFeature,
              message: 'This backend does not support selection outlines.',
              operation: 'render',
              requiredFeatures: {RenderFeature.selectionOutlines},
            ),
          );
        }
      }
      if (!capabilities.supports(RenderFeature.meshShaders) &&
          _hasVisibleShaderMaterial(scene, camera.layers)) {
        throw SceneException(
          SceneIssue(
            code: SceneIssueCodes.unsupportedFeature,
            message: 'This backend does not support mesh shaders.',
            operation: 'render',
          ),
        );
      }
      if (_hasVisibleStandardMaterial(scene, camera.layers) &&
          !capabilities.supports(RenderFeature.standardMaterials)) {
        throw SceneException(
          SceneIssue(
            code: SceneIssueCodes.unsupportedFeature,
            message: 'This backend does not support standard materials.',
            operation: 'render',
            requiredFeatures: {RenderFeature.standardMaterials},
          ),
        );
      }
      if (_hasVisiblePhysicalMaterial(scene, camera.layers) &&
          !capabilities.supports(RenderFeature.physicalMaterials)) {
        throw SceneException(
          SceneIssue(
            code: SceneIssueCodes.unsupportedFeature,
            message: 'This backend does not support physical materials.',
            operation: 'render',
            requiredFeatures: {RenderFeature.physicalMaterials},
          ),
        );
      }
      final areaCount = _visibleAreaLightCount(scene, camera.layers);
      if (areaCount > capabilities.limits.maxAreaLights ||
          (areaCount > 0 &&
              !capabilities.supports(RenderFeature.areaLighting))) {
        throw SceneException(
          SceneIssue(
            code: SceneIssueCodes.unsupportedFeature,
            message:
                'This scene exceeds the backend area-light capability or capacity.',
            operation: 'render',
            requiredFeatures: {RenderFeature.areaLighting},
            limits: capabilities.limits,
          ),
        );
      }
      _checkDeformation(scene, capabilities, camera.layers);
      final instanceCapacity = _instanceCapacity(scene);
      if (instanceCapacity > 0 &&
          (!capabilities.supports(RenderFeature.instancing) ||
              instanceCapacity > capabilities.limits.maxInstances)) {
        throw SceneException(
          SceneIssue(
            code: SceneIssueCodes.unsupportedFeature,
            message:
                'This scene exceeds the backend instance capability or capacity.',
            operation: 'render',
            requiredFeatures: {RenderFeature.instancing},
            limits: capabilities.limits,
          ),
        );
      }
      if (_hasVisibleShadows(scene, camera.layers) &&
          !capabilities.supports(RenderFeature.shadows)) {
        throw SceneException(
          SceneIssue(
            code: SceneIssueCodes.unsupportedFeature,
            message: 'This backend does not support shadows.',
            operation: 'render',
            requiredFeatures: {RenderFeature.shadows},
          ),
        );
      }
      if (_visibleLightCount(scene, camera.layers) >
              capabilities.limits.maxPunctualLights ||
          _visibleHemisphereLightCount(scene, camera.layers) >
              capabilities.limits.maxHemisphereLights) {
        throw SceneException(
          SceneIssue(
            code: SceneIssueCodes.unsupportedFeature,
            message: "The scene exceeds this backend's light limits.",
            operation: 'render',
            limits: capabilities.limits,
          ),
        );
      }
      final FrameOutput result;
      if (_backend case final backend?) {
        final sceneRevision = scene.revision, cameraRevision = camera.revision;
        var submission = FrameSubmission.capture(
          aspectRatio: aspectRatio,
          scene: scene,
          camera: camera,
          size: PhysicalSize(width, height),
          time: time ?? FrameTime(elapsed: elapsed, delta: delta),
          target: target,
          graph: graph ?? _frameGraph?.graph,
          colorPipeline: colorPipeline,
          environment: _environment?.environment,
          temporalAA: _temporal?.options,
          temporalReset: _temporal?.generation ?? 0,
        );
        final source =
            sceneRevision == scene.revision && cameraRevision == camera.revision
            ? FrameSource(
                sceneRevision: sceneRevision,
                cameraRevision: cameraRevision,
                cameraRuntimeId: camera.id,
              )
            : null;
        if (_sharedGraph case final shared?) {
          submission = submission.withGraph(
            await shared.prepare(
              submission.size,
              submission.camera.projection,
              colorPipeline == null && !submission.scene.usesScreenEffects
                  ? TextureFormat.rgba8UnormSrgb
                  : TextureFormat.rgba16Float,
            ),
          );
        }
        final rendered = await backend.render(submission);
        FrameSource? presentedSource = source;
        if (rendered.stats.admission?.candidateReady == false) {
          final published = _publishedSource;
          presentedSource = published == null || source == null
              ? null
              : FrameSource(
                  sceneRevision: published.sceneRevision,
                  cameraRevision: source.cameraRevision,
                  cameraRuntimeId: source.cameraRuntimeId,
                );
        } else {
          _publishedSource = source;
        }
        result = presentedSource == null
            ? rendered
            : rendered.withStats(rendered.stats.withSource(presentedSource));
        _sharedGraph?.completeFrame(submission.graph);
      } else {
        if (target is! ReadbackTarget) {
          throw StateError(
            'The legacy renderer supports explicit readback only.',
          );
        }
        final frame = await _renderer!.render(
          scene,
          camera,
          width: width,
          height: height,
        );
        result = ReadbackOutput(
          image: ImageData(
            pixels: frame.pixels,
            size: PhysicalSize(frame.width, frame.height),
            alphaMode: frame.alphaMode,
          ),
          stats: FrameStats(
            frameId: info.number,
            physicalSize: PhysicalSize(width, height),
            presentationPath: PresentationPath.readback,
            cpuBuildTime: Duration.zero,
            cpuSubmitTime: Duration.zero,
            drawCalls: 0,
            triangles: 0,
            uploadedBytes: 0,
            readbackBytes: frame.pixels.length,
          ),
        );
      }
      // The backend has already published. Every state owner needs its receipt
      // even when a peer hook fails; report the first error after notification.
      (Object, StackTrace)? receiptError;
      for (final (plugin, context) in _attached) {
        try {
          await _hook(() => plugin.afterRender(context, info, result.stats));
        } catch (error, stack) {
          receiptError ??= (error, stack);
        }
      }
      if (!_closed && result.stats.admission?.candidateReady == false) {
        try {
          _onInvalidate?.call();
        } catch (error, stack) {
          receiptError ??= (error, stack);
        }
      }
      if (receiptError case final failure?) {
        Error.throwWithStackTrace(failure.$1, failure.$2);
      }
      return result;
    });
    _frame = future;
    return future.whenComplete(() {
      _frame = null;
    });
  }

  /// Reconcile a complete desired graph without replacing the renderer.
  /// Validation happens before detaching anything. On attachment failure,
  /// newly attached candidates are removed and unaffected plugins remain.
  /// Inspect [pluginIds] for the actual configuration, then retry explicitly.
  /// Calls from this engine's plugin hooks are rejected to avoid deadlocks.
  Future<void> updatePlugins(List<ScenePlugin> plugins) =>
      _queuePlugins(plugins);

  Future<void> dispose() => _disposal ??= _dispose();
  Future<void> _dispose() async {
    _closed = true;
    _sharedGraph?.stop();
    final errors = <Object>[];
    for (final (_, context) in _attached.reversed) {
      try {
        context.scope.close();
      } catch (_) {
        // whenClosed reports synchronous and asynchronous cleanup together.
      }
    }
    await _pluginUpdates;
    try {
      await _frame;
    } catch (_) {
      /* The frame caller receives this error. */
    }
    try {
      await _sharedGraph?.close();
    } catch (error) {
      errors.add(error);
    }
    for (final (plugin, context) in _attached.reversed) {
      try {
        await context.scope.whenClosed;
      } catch (error) {
        errors.add(error);
      }
      try {
        await _hook(() => plugin.detach(context));
      } catch (error) {
        errors.add(error);
      } finally {
        context._close();
      }
    }
    try {
      await _backend?.close();
      await _renderer?.dispose();
    } catch (error) {
      errors.add(error);
    } finally {
      for (final plugin in _plugins) {
        if (identical(_owners[plugin], _owner)) _owners[plugin] = null;
      }
    }
    _cancellation?.dispose();
    if (errors.isNotEmpty) throw EngineCleanupException(errors);
  }
}

SceneException _cancelled([Object? cause]) => SceneException(
  SceneIssue(
    code: SceneIssueCodes.disposed,
    operation: 'attach',
    message: 'Engine attachment was cancelled.',
    cause: cause,
  ),
);

bool _hasVisibleShaderMaterial(Object3D node, LayerMask layers) =>
    node.visible &&
    ((node is Mesh &&
            node.layers.intersects(layers) &&
            node.material is ShaderMaterial) ||
        node.renderChildren.any(
          (child) => _hasVisibleShaderMaterial(child, layers),
        ));

bool _hasVisibleStandardMaterial(Object3D node, LayerMask layers) =>
    node.visible &&
    ((node is Mesh &&
            node.layers.intersects(layers) &&
            node.material is StandardMaterial) ||
        node.renderChildren.any(
          (child) => _hasVisibleStandardMaterial(child, layers),
        ));
bool _hasVisiblePhysicalMaterial(Object3D node, LayerMask layers) =>
    node.visible &&
    ((node is Mesh &&
            node.layers.intersects(layers) &&
            node.material is PhysicalMaterial) ||
        node.renderChildren.any(
          (child) => _hasVisiblePhysicalMaterial(child, layers),
        ));
int _visibleLightCount(Object3D node, LayerMask layers) => !node.visible
    ? 0
    : (node is PunctualLight && node.layers.intersects(layers) ? 1 : 0) +
          node.renderChildren.fold(
            0,
            (sum, child) => sum + _visibleLightCount(child, layers),
          );

int _visibleAreaLightCount(Object3D node, LayerMask layers) => !node.visible
    ? 0
    : (node is RectAreaLight && node.layers.intersects(layers) ? 1 : 0) +
          node.renderChildren.fold(
            0,
            (sum, child) => sum + _visibleAreaLightCount(child, layers),
          );
int _visibleHemisphereLightCount(Object3D node, LayerMask layers) =>
    !node.visible
    ? 0
    : (node is HemisphereLight && node.layers.intersects(layers) ? 1 : 0) +
          node.renderChildren.fold(
            0,
            (sum, child) => sum + _visibleHemisphereLightCount(child, layers),
          );

bool _hasVisibleShadows(Object3D node, LayerMask layers) =>
    node.visible &&
    ((node is PunctualLight &&
            node.layers.intersects(layers) &&
            node.shadow != null) ||
        (node is Mesh &&
            node.layers.intersects(layers) &&
            (node.castShadow || node.receiveShadow)) ||
        node.renderChildren.any((child) => _hasVisibleShadows(child, layers)));

int _instanceCapacity(Object3D node) =>
    (node is InstancedMesh ? node.capacity : 0) +
    node.renderChildren.fold<int>(
      0,
      (n, child) => n + _instanceCapacity(child),
    );

void _checkDeformation(
  Object3D node,
  DeviceCapabilities capabilities,
  LayerMask layers,
) {
  if (!node.visible) return;
  if (node is Mesh && node.layers.intersects(layers)) {
    final required = <RenderFeature>{};
    if (node is SkinnedMesh &&
        (!capabilities.supports(RenderFeature.skinning) ||
            node.skin.joints.length > capabilities.limits.maxJoints)) {
      required.add(RenderFeature.skinning);
    }
    if (node.geometry.morphTargets.isNotEmpty &&
        (!capabilities.supports(RenderFeature.morphTargets) ||
            node.geometry.morphTargets.length >
                capabilities.limits.maxMorphTargets)) {
      required.add(RenderFeature.morphTargets);
    }
    if (required.isNotEmpty) {
      throw SceneException(
        SceneIssue(
          code: SceneIssueCodes.unsupportedFeature,
          message:
              'This mesh exceeds the backend deformation capability or limits.',
          operation: 'render',
          requiredFeatures: required,
          limits: capabilities.limits,
        ),
      );
    }
  }
  for (final child in node.renderChildren) {
    _checkDeformation(child, capabilities, layers);
  }
}

final class _FramePreparation {
  final Map<Object, Object> services;
  final FrameInfo frame;
  bool active = true;
  _FramePreparation(this.services, this.frame);
}
