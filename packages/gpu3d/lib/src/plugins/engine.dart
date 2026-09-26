import 'dart:async';
import 'registration.dart';
import 'attachment_scope.dart';
import '../input/pointer_event.dart';
import '../rendering/capabilities.dart';
import '../rendering/scene_issue.dart';
import '../rendering/renderer.dart';
import '../rendering/frame_submission.dart';
import '../scene/scene.dart';

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
  FutureOr<void> attach(PluginContext context) {}
  FutureOr<void> beforeRender(PluginContext context, FrameInfo frame) {}
  FutureOr<void> afterRender(
    PluginContext context,
    FrameInfo info,
    RenderedFrame frame,
  ) {}

  /// Also called after a failed attach, so tolerate partial initialization.
  FutureOr<void> detach(PluginContext context) {}
}

/// Services belong to this engine, never to a process-wide registry.
class PluginContext {
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
    this.scene,
    this.camera,
    this.capabilities,
    this._services,
    this._invalidate,
    this._demand,
    this.input,
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

/// Owns a renderer and an immutable plugin configuration, with no widget state.
class SceneEngine {
  static final _owners = Expando<Object>('ScenePlugin owner');
  final Scene scene;
  Camera _camera;
  Camera get camera => _camera;
  set camera(Camera value) {
    if (_closed) throw StateError('Engine has been disposed.');
    _camera = value;
    for (final (_, context) in _attached) {
      context.camera = value;
    }
  }

  final SceneRenderer _renderer;
  final List<ScenePlugin> _plugins;
  final Object _owner;
  final Map<Object, Object> _services = {};
  final List<(ScenePlugin, PluginContext)> _attached = [];
  Future<RenderedFrame>? _frame;
  Future<void>? _disposal;
  Registration? _cancellation;
  Duration? _lastElapsed;
  int _frameNumber = 0;
  bool _closed = false;

  SceneEngine._(
    this.scene,
    this._camera,
    this._renderer,
    this._plugins,
    this._owner,
  );
  RendererCapabilities get capabilities => _renderer.capabilities;
  List<String> get pluginIds => List.unmodifiable(_plugins.map((p) => p.id));

  static Future<SceneEngine> create({
    required Scene scene,
    required Camera camera,
    required RendererFactory rendererFactory,
    List<ScenePlugin> plugins = const [],
    InputSource? input,
    AttachmentScope? lifetime,
    void Function()? onInvalidate,
    Registration Function()? acquireFrameDemand,
  }) async {
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
      final renderer = await rendererFactory();
      engine = SceneEngine._(scene, camera, renderer, ordered, owner);
      if (cancelled) throw _cancelled();
      for (final plugin in ordered) {
        final missing = plugin.requiredFeatures.difference(
          renderer.capabilities.features,
        );
        if (missing.isNotEmpty) {
          throw SceneException(
            SceneIssue(
              code: SceneIssueCodes.unsupportedFeature,
              operation: 'attach',
              pluginId: plugin.id,
              requiredFeatures: Set.unmodifiable(missing),
              limits: renderer.capabilities.limits,
              message:
                  'Plugin ${plugin.id} requires unsupported features: ${missing.map((feature) => feature.name).join(', ')}.',
            ),
          );
        }
      }
      for (final plugin in ordered) {
        final context = PluginContext._(
          scene,
          camera,
          renderer.capabilities,
          engine._services,
          onInvalidate,
          acquireFrameDemand,
          input,
        );
        engine._attached.add((plugin, context));
        try {
          attaching = true;
          await plugin.attach(context);
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
    return List.unmodifiable(ordered);
  }

  Future<RenderedFrame> render({
    required Duration elapsed,
    FrameTime? time,
    required int width,
    required int height,
  }) {
    if (_closed) return Future.error(StateError('Engine has been disposed.'));
    if (_frame != null) {
      return Future.error(StateError('Only one frame may be in flight.'));
    }
    if (elapsed.isNegative ||
        width < 1 ||
        height < 1 ||
        width > capabilities.maxDimension ||
        height > capabilities.maxDimension) {
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
    final future = Future<RenderedFrame>.microtask(() async {
      for (final (plugin, context) in _attached) {
        await plugin.beforeRender(context, info);
      }
      final result = await _renderer.render(
        scene,
        camera,
        width: width,
        height: height,
      );
      for (final (plugin, context) in _attached) {
        await plugin.afterRender(context, info, result);
      }
      return result;
    });
    _frame = future;
    return future.whenComplete(() {
      _frame = null;
    });
  }

  Future<void> dispose() => _disposal ??= _dispose();
  Future<void> _dispose() async {
    _closed = true;
    final errors = <Object>[];
    for (final (_, context) in _attached.reversed) {
      try {
        context.scope.close();
      } catch (_) {
        // whenClosed reports synchronous and asynchronous cleanup together.
      }
    }
    try {
      await _frame;
    } catch (_) {
      /* The frame caller receives this error. */
    }
    for (final (plugin, context) in _attached.reversed) {
      try {
        await context.scope.whenClosed;
      } catch (error) {
        errors.add(error);
      }
      try {
        await plugin.detach(context);
      } catch (error) {
        errors.add(error);
      } finally {
        context._close();
      }
    }
    try {
      await _renderer.dispose();
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
