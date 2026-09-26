import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import '../presentation.dart';
import '../input/flutter_input_adapter.dart';
import '../diagnostics/renderer_info.dart';
import 'backend_renderer.dart';
import 'scene_runtime.dart';
import 'scene_status.dart';
part '../viewport/scene_view.dart';

/// Owns one native session. A borrowed view leaves it alive when unmounted.
class SceneController {
  final Scene scene;
  Camera _camera;
  final EngineOptions options;
  final SceneRuntime runtime;
  final _input = FlutterInputAdapter();
  final assets = AssetScope();
  final _registrations = AttachmentScope();
  AttachmentScope _lifetime = AttachmentScope();
  final _cleanupErrors = <Object>[];
  Future<void>? _assetDisposal;
  InputSource get input => _input;
  final List<ScenePlugin> _plugins = [];
  final Map<Object, void Function(FrameTime)> _updates = {};
  late final FrameScheduler _scheduler;
  final _status = ValueNotifier<SceneStatus>(const SceneDetached(0));
  final _issues = StreamController<SceneIssue>.broadcast();
  final _stats = StreamController<FrameStats>.broadcast();
  final _disposed = Completer<void>();
  Completer<RendererInfo> _ready = Completer();
  Completer<FrameStats> _firstFrame = Completer();
  late final StreamSubscription<int> _sceneSubscription;
  late StreamSubscription<int> _cameraSubscription;
  SceneEngine? _engine;
  BackendRenderer? _renderer;
  RendererInfo? _info;
  Future<void>? _initialization, _drawing, _failureCleanup, _retrying;
  Object? _viewToken;
  String? _viewLabel;
  int _generation = 0;
  bool _closed = false, _visible = false;
  Future<void> Function()? _closePresentation;
  Future<void>? _presentationDisposal, _retiring;
  Duration? _lastStats;
  void Function()? _wakeView;
  bool _wakeScheduled = false, _automaticRecoveryUsed = false;
  void _scheduleWake() {
    if (_wakeScheduled || _closed) return;
    _wakeScheduled = true;
    scheduleMicrotask(() {
      _wakeScheduled = false;
      if (!_closed) _wakeView?.call();
    });
  }

  SceneController({
    Scene? scene,
    Camera? camera,
    this.options = const EngineOptions(),
    SceneRuntime? runtime,
  }) : scene = scene ?? Scene(),
       _camera = camera ?? PerspectiveCamera(),
       runtime = runtime ?? const SceneRuntime() {
    options.validate();
    _scheduler = FrameScheduler(
      maxFramesPerSecond: options.maxFramesPerSecond,
      onChanged: _scheduleWake,
    )..setVisible(false);
    if (options.renderMode == RenderMode.continuous) _scheduler.acquireDemand();
    _sceneSubscription = this.scene.changes.listen((_) => _scheduler.request());
    _cameraSubscription = _camera.changes.listen((_) => _scheduler.request());
    _observeReadiness();
    _disposed.future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }
  Camera get camera => _camera;
  set camera(Camera value) {
    _checkOpen();
    if (identical(_camera, value)) return;
    unawaited(_cameraSubscription.cancel());
    _camera = value;
    _cameraSubscription = value.changes.listen((_) => _scheduler.request());
    _engine?.camera = value;
    invalidate();
  }

  ValueListenable<SceneStatus> get status => _status;
  Stream<SceneIssue> get issues => _issues.stream;
  Stream<FrameStats> get frameStats => _stats.stream;
  Future<RendererInfo> get ready => _ready.future;
  Future<FrameStats> get firstFrame => _firstFrame.future;
  Future<void> get whenDisposed => _disposed.future;
  bool get isDisposed => _closed;
  List<String> get pluginIds => List.unmodifiable(_plugins.map((p) => p.id));
  void _checkOpen() {
    if (_closed) throw StateError('SceneController has been disposed.');
  }

  void update(void Function() changes) {
    _checkOpen();
    scene.batch(changes);
  }

  void invalidate() {
    _checkOpen();
    _scheduler.request();
  }

  Registration onUpdate(void Function(FrameTime) callback) {
    _checkOpen();
    final key = Object();
    _updates[key] = callback;
    final demand = _scheduler.acquireDemand();
    return _registrations.keep(
      Registration(() {
        _updates.remove(key);
        demand.dispose();
      }),
    );
  }

  T use<T extends ScenePlugin>(T plugin) {
    _checkOpen();
    if (_initialization != null || _engine != null) {
      throw StateError('Register plugins before the first attachment.');
    }
    if (_plugins.any((p) => p.id == plugin.id)) {
      throw ArgumentError('Duplicate plugin ID: ${plugin.id}.');
    }
    _plugins.add(plugin);
    return plugin;
  }

  void _observeReadiness() {
    // These futures remain errors for callers; unattended view futures are safe.
    _ready.future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _firstFrame.future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }

  SceneException _exception(
    String code,
    String message,
    String operation, [
    Object? cause,
  ]) => SceneException(
    SceneIssue(
      code: code,
      message: message,
      operation: operation,
      cause: cause,
    ),
  );
  void _attach(Object token, String label) {
    _checkOpen();
    if (_viewToken != null && !identical(_viewToken, token)) {
      throw _exception(
        SceneIssueCodes.controllerAlreadyAttached,
        'Controller is already attached to $_viewLabel; cannot attach $label.',
        'attach',
      );
    }
    _viewToken = token;
    _viewLabel = label;
    _scheduler.request();
  }

  void _detach(Object token) {
    if (!identical(_viewToken, token)) return;
    _viewToken = null;
    _viewLabel = null;
    _wakeView = null;
    _visible = false;
    _scheduler.setVisible(false);
    final closePresentation = _closePresentation;
    _closePresentation = null;
    if (closePresentation != null) {
      final previous = _retiring;
      final closing = closePresentation();
      final retirement = Future.wait<void>([
        ?previous,
        closing,
      ]).then<void>((_) {});
      _retiring = retirement;
      retirement.then<void>(
        (_) {
          if (identical(_retiring, retirement)) _retiring = null;
        },
        onError: (Object error, StackTrace stack) {
          _fail(error, stack, 'cleanup');
        },
      );
    }
    if (!_closed && _status.value is! SceneFailed) {
      _status.value = SceneDetached(_generation);
    }
  }

  void _setVisible(bool value) {
    _scheduler.setVisible(value);
    if (_visible == value) return;
    _visible = value;
    if (_closed || _status.value is SceneFailed || _engine == null) return;
    _status.value = value
        ? SceneReady(_generation, _info!)
        : SceneSuspended(_generation);
  }

  void _start() {
    if (_closed ||
        _viewToken == null ||
        _initialization != null ||
        _engine != null ||
        _status.value is SceneFailed) {
      return;
    }
    final generation = _generation;
    _initialization = Future<void>.microtask(() => _initialize(generation));
    _status.value = SceneInitializing(generation);
  }

  Future<void> _initialize(int generation) async {
    try {
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        plugins: List.of(_plugins),
        input: _input,
        lifetime: _lifetime,
        onInvalidate: _scheduler.request,
        acquireFrameDemand: _scheduler.acquireDemand,
        rendererFactory: () async {
          final backend = await runtime.backendFactory();
          if (_closed || generation != _generation) {
            await backend.close();
            throw _exception(
              SceneIssueCodes.disposed,
              'Controller closed during backend creation.',
              'initialize',
            );
          }
          // No native shared-surface adapter is installed yet. Never hide readback.
          if (options.presentation == PresentationPolicy.requireSharedTexture) {
            await backend.close();
            throw _exception(
              SceneIssueCodes.presentationUnavailable,
              'Shared texture presentation is unavailable. Select readbackOnly or allowReadback explicitly.',
              'initialize',
            );
          }
          if (!backend.capabilities.supports(RenderFeature.rgbaReadback)) {
            await backend.close();
            throw _exception(
              SceneIssueCodes.unsupportedFeature,
              'The selected backend does not support RGBA readback.',
              'initialize',
            );
          }
          _renderer = BackendRenderer(backend);
          _info = RendererInfo(
            backend: backend.capabilities.backend ?? backend.capabilities.name,
            adapterName: backend.capabilities.adapterName,
            driverDescription: backend.capabilities.driverDescription,
            capabilities: backend.capabilities,
            presentationPath: PresentationPath.readback,
          );
          return _renderer!;
        },
      );
      if (_closed || generation != _generation) {
        await engine.dispose();
        return;
      }
      _engine = engine;
      _engine!.camera = camera;
      if (!_ready.isCompleted) _ready.complete(_info!);
      _status.value = _viewToken == null
          ? SceneDetached(generation)
          : _visible
          ? SceneReady(generation, _info!)
          : SceneSuspended(generation);
      _scheduler.request();
    } catch (error, stack) {
      if (_closed) {
        if (error is SceneException &&
            error.issue.code == SceneIssueCodes.disposed) {
          return;
        }
        Error.throwWithStackTrace(error, stack);
      }
      if (generation == _generation) {
        _fail(error, stack, 'initialize');
      }
    }
  }

  void _fail(Object error, StackTrace stack, String operation) {
    if (_closed) return;
    final exception = error is SceneException
        ? error
        : _exception(
            operation == 'render'
                ? SceneIssueCodes.renderFailed
                : SceneIssueCodes.backendUnavailable,
            error.toString(),
            operation,
            error,
          );
    if (!_ready.isCompleted) _ready.completeError(exception, stack);
    if (!_firstFrame.isCompleted) _firstFrame.completeError(exception, stack);
    _scheduler.setVisible(false);
    _status.value = SceneFailed(_generation, exception.issue);
    _issues.add(exception.issue);
    final failedEngine = _engine;
    _engine = null;
    if (failedEngine != null) {
      _failureCleanup = Future<void>.microtask(() async {
        await _drawing;
        await failedEngine.dispose();
      });
      _failureCleanup!.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    }
    if (exception.issue.code == SceneIssueCodes.deviceLost &&
        options.recovery == RecoveryPolicy.automaticOnce &&
        !_automaticRecoveryUsed) {
      _automaticRecoveryUsed = true;
      scheduleMicrotask(() {
        if (!_closed && _status.value is SceneFailed) unawaited(retry());
      });
    }
  }

  Future<(RenderedFrame, FrameStats)> _render(
    FrameTime time,
    PhysicalSize size,
  ) {
    final completer = Completer<(RenderedFrame, FrameStats)>();
    _drawing = Future<void>.microtask(() async {
      try {
        _checkOpen();
        for (final entry in List.of(_updates.entries)) {
          if (_closed) break;
          if (_updates.containsKey(entry.key)) entry.value(time);
        }
        _checkOpen();
        _renderer!.time = time;
        final frame = await _engine!.render(
          elapsed: time.elapsed,
          time: time,
          width: size.width,
          height: size.height,
        );
        completer.complete((frame, _renderer!.stats!));
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  void _presented(FrameStats stats, FrameTime time) {
    if (_closed) return;
    if (!_firstFrame.isCompleted) _firstFrame.complete(stats);
    if (_lastStats == null ||
        time.elapsed - _lastStats! >= const Duration(milliseconds: 200)) {
      _lastStats = time.elapsed;
      _stats.add(stats);
    }
  }

  Future<void> retry() {
    _checkOpen();
    if (_status.value is! SceneFailed) {
      throw StateError('Retry requires a failed scene.');
    }
    return _retrying = _retry();
  }

  Future<void> _retry() async {
    _generation++;
    _ready = Completer();
    _firstFrame = Completer();
    _observeReadiness();
    _status.value = SceneRecovering(_generation);
    final closePresentation = _closePresentation?.call();
    try {
      await _initialization;
      await _drawing;
      await _failureCleanup;
      await closePresentation;
      await _retiring;
      final old = _engine;
      _engine = null;
      _renderer = null;
      await old?.dispose();
    } catch (error, stack) {
      if (!_closed) _fail(error, stack, 'cleanup');
      return;
    }
    if (_closed) return;
    _lifetime = AttachmentScope();
    _failureCleanup = null;
    _initialization = null;
    _status.value = SceneDetached(_generation);
    _scheduler.request();
    if (_viewToken != null) _start();
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _scheduler.setVisible(false);
    for (final scope in [_registrations, _lifetime]) {
      try {
        scope.close();
      } catch (error) {
        _cleanupErrors.add(error);
      }
    }
    _updates.clear();
    _assetDisposal = assets.close();
    _assetDisposal!.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _input.close();
    unawaited(_sceneSubscription.cancel());
    unawaited(_cameraSubscription.cancel());
    final error = _exception(
      SceneIssueCodes.disposed,
      'SceneController has been disposed.',
      'dispose',
    );
    if (!_ready.isCompleted) _ready.completeError(error);
    if (!_firstFrame.isCompleted) _firstFrame.completeError(error);
    _presentationDisposal = _closePresentation?.call();
    _status.value = SceneDisposed(_generation);
    unawaited(_close());
  }

  Future<void> _close() async {
    final errors = List<Object>.of(_cleanupErrors);
    for (final close in <Future<void>? Function()>[
      () => _registrations.whenClosed,
      () => _lifetime.whenClosed,
      () => _assetDisposal,
      () => _retrying,
      () => _initialization,
      () => _drawing,
      () => _failureCleanup,
      () => _presentationDisposal,
      () => _retiring,
      () => _engine?.dispose(),
    ]) {
      try {
        await close();
      } catch (error) {
        errors.add(error);
      }
    }
    _engine = null;
    _renderer = null;
    if (errors.isEmpty) {
      _disposed.complete();
    } else {
      final exception = _exception(
        SceneIssueCodes.cleanupFailed,
        errors.join('; '),
        'dispose',
        EngineCleanupException(errors),
      );
      _issues.add(exception.issue);
      _disposed.completeError(exception);
    }
    unawaited(_issues.close());
    unawaited(_stats.close());
  }
}
