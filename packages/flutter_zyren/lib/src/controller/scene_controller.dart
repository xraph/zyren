import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import '../presentation.dart';
import '../input/flutter_input_adapter.dart';
import '../diagnostics/renderer_info.dart';
import '../diagnostics/presentation_sample.dart';
import '../presentation/output_presenter.dart';
import 'scene_runtime.dart';
import 'scene_status.dart';
part '../viewport/scene_view.dart';
part 'scene_state.dart';

/// Owns one native session. A borrowed view leaves it alive when unmounted.
class SceneController {
  final Scene scene;
  Camera _camera;
  final EngineOptions options;
  ColorPipeline? _colorPipeline;
  ColorPipeline? get colorPipeline => _colorPipeline;
  set colorPipeline(ColorPipeline? value) {
    _checkOpen();
    _colorPipeline = value;
    invalidate();
  }

  final SceneRuntime runtime;
  final _input = FlutterInputAdapter();
  late final AssetScope assets;
  final _registrations = AttachmentScope();
  AttachmentScope _lifetime = AttachmentScope();
  final _cleanupErrors = <Object>[];
  Future<void>? _assetDisposal;
  InputSource get input => _input;
  final List<ScenePlugin> _plugins = [];
  Future<void> _pluginSync = Future.value();
  SceneIssue? _pluginIssue;
  Object3D? _selection;
  double _devicePixelRatio = 1;
  late final _SceneStateListenable _state = _SceneStateListenable(
    _captureState,
  );

  /// Current immutable values. Camera and selected object references retain identity.
  ValueListenable<SceneState> get state => _state;
  SceneIssue? get pluginIssue => _pluginIssue;
  Object3D? get selection => _attachedSelection;
  set selection(Object3D? value) {
    _checkOpen();
    if (value != null && !_belongsToScene(value)) {
      throw ArgumentError('Selection must belong to this controller scene.');
    }
    if (identical(value, _selection)) return;
    _selection = value;
    _publishState();
  }

  bool _belongsToScene(Object3D value) {
    Object3D root = value;
    while (root.parent != null) {
      root = root.parent!;
    }
    return identical(root, scene);
  }

  Object3D? get _attachedSelection {
    if (_selection != null && !_belongsToScene(_selection!)) _selection = null;
    return _selection;
  }

  List<String> _snapshotPluginIds = const [];
  List<String> _stablePluginIds() {
    final current = pluginIds;
    if (!listEquals(current, _snapshotPluginIds)) {
      _snapshotPluginIds = List.unmodifiable(current);
    }
    return _snapshotPluginIds;
  }

  SceneState _captureState() => SceneState._(
    camera: camera,
    cameraPosition: camera.position,
    cameraTarget: camera.target,
    cameraUp: camera.up,
    cameraRevision: camera.revision,
    viewport: SceneViewport(_viewportSize, _devicePixelRatio),
    selection: _attachedSelection,
    status: _status.value,
    renderer: _info,
    frameStats: _latestFrameStats,
    pluginIds: _stablePluginIds(),
    pluginIssue: _pluginIssue,
  );
  void _publishState() => _state.publish();
  void _sceneChanged() {
    _attachedSelection;
    _scheduler.request();
    _publishState();
  }

  void _setPixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    _publishState();
  }

  final Map<Object, void Function(FrameTime)> _updates = {};
  late final FrameScheduler _scheduler;
  final _status = ValueNotifier<SceneStatus>(const SceneDetached(0));
  final _issues = StreamController<SceneIssue>.broadcast();
  final _stats = StreamController<FrameStats>.broadcast();
  final _presentationClock = Stopwatch()..start();
  Duration? _previousPresentation;
  late final _presentations = StreamController<PresentationSample>.broadcast(
    onListen: () => _previousPresentation = null,
  );
  final _disposed = Completer<void>();
  Completer<RendererInfo> _ready = Completer();
  Completer<FrameStats> _firstFrame = Completer();
  late final StreamSubscription<int> _sceneSubscription;
  late StreamSubscription<int> _cameraSubscription;
  SceneEngine? _engine;
  RenderBackend? _backend;
  OutputPresenter _createPresenter() => switch (_info!.presentationPath) {
    PresentationPath.sharedTexture => runtime.surfacePresenterFactory!.create(
      _backend!,
    ),
    PresentationPath.nativeView => runtime.nativeViewPresenterFactory!.create(
      _backend!,
    ),
    PresentationPath.readback => ReadbackPresenter(runtime.presenterFactory()),
  };
  RendererInfo? _info;
  Future<void>? _initialization, _drawing, _failureCleanup, _retrying;
  Object? _viewToken;
  String? _viewLabel;
  Size _viewportSize = Size.zero;
  Size get _logicalSize => _viewportSize;
  set _logicalSize(Size value) {
    if (_viewportSize == value) return;
    _viewportSize = value;
    _publishState();
    _input.logicalWidth = value.width;
    _input.logicalHeight = value.height;
  }

  final _raycaster = Raycaster();
  int _generation = 0;
  bool _closed = false, _visible = false;
  Future<void> Function()? _closePresentation;
  Future<void>? _presentationDisposal, _retiring;
  Timer? _statsTimer;
  FrameStats? _pendingStats;
  FrameStats? _latestFrameStats;
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
    ColorPipeline? colorPipeline,
    SceneRuntime? runtime,
  }) : _colorPipeline = colorPipeline,
       scene = scene ?? Scene(),
       _camera = camera ?? PerspectiveCamera(),
       runtime = runtime ?? const SceneRuntime() {
    options.validate();
    assets = AssetScope(services: this.runtime.assetServices);
    _scheduler = FrameScheduler(
      maxFramesPerSecond: options.maxFramesPerSecond,
      onChanged: _scheduleWake,
    )..setVisible(false);
    if (options.renderMode == RenderMode.continuous) _scheduler.acquireDemand();
    _sceneSubscription = this.scene.changes.listen((_) => _sceneChanged());
    _cameraSubscription = _camera.changes.listen((_) => _sceneChanged());
    _status.addListener(_publishState);
    _observeReadiness();
    _disposed.future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }
  Camera get camera => _camera;
  set camera(Camera value) {
    _checkOpen();
    if (identical(_camera, value)) return;
    unawaited(_cameraSubscription.cancel());
    _camera = value;
    _cameraSubscription = value.changes.listen((_) => _sceneChanged());
    _engine?.camera = value;
    invalidate();
  }

  ValueListenable<SceneStatus> get status => _status;
  Stream<SceneIssue> get issues => _issues.stream;

  /// Samples at most every 200 ms and publishes the last pending frame even
  /// when demand rendering stops. The first presented frame emits immediately.
  Stream<FrameStats> get frameStats => _stats.stream;

  /// Every accepted presentation, without diagnostic throttling or history.
  /// Samples are created only while this broadcast stream has listeners.
  /// Keep listeners short; use [frameStats] for a sampled UI counter.
  Stream<PresentationSample> get presentations => _presentations.stream;

  /// Most recently presented frame, including one awaiting the sampled stream.
  /// Remains available while idle or suspended. Failure and disposal clear it.
  FrameStats? get latestFrameStats => _latestFrameStats;
  Future<RendererInfo> get ready => _ready.future;
  Future<FrameStats> get firstFrame => _firstFrame.future;
  Future<void> get whenDisposed => _disposed.future;
  bool get isDisposed => _closed;

  /// Actual attached plugins once ready, or requested plugins before attachment.
  List<String> get pluginIds =>
      _engine?.pluginIds ?? List.unmodifiable(_plugins.map((p) => p.id));
  List<ScenePlugin> get requestedPlugins => List.unmodifiable(_plugins);
  List<String> get desiredPluginIds =>
      List.unmodifiable(_plugins.map((p) => p.id));
  void _checkOpen() {
    if (_closed) throw StateError('SceneController has been disposed.');
  }

  void update(void Function() changes) {
    _checkOpen();
    scene.batch(changes);
  }

  /// Selects the nearest triangle using this view's logical coordinates.
  /// Scene, camera and viewport state are captured synchronously. The future
  /// returns that captured result even if the scene changes before completion.
  Future<PickResult?> pick(ViewportPoint point) {
    try {
      final snapshot = capturePick(point);
      return Future<PickResult?>.microtask(snapshot.intersectFirst);
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  /// Captures hits synchronously for input arbitration and deferred delivery.
  RaycastSnapshot capturePick(ViewportPoint point) {
    if (_closed) {
      throw _exception(
        SceneIssueCodes.disposed,
        'SceneController has been disposed.',
        'pick',
      );
    }
    if (_viewToken == null || _logicalSize.isEmpty) {
      throw _exception(
        SceneIssueCodes.invalidPickRequest,
        'Picking requires an attached view with a positive logical extent.',
        'pick',
      );
    }
    return _raycaster.captureFromCamera(
      scene,
      camera,
      point,
      logicalWidth: _logicalSize.width,
      logicalHeight: _logicalSize.height,
    );
  }

  Future<List<PickResult>> pickAll(ViewportPoint point) {
    try {
      final snapshot = capturePick(point);
      return Future<List<PickResult>>.microtask(snapshot.intersectAll);
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  void invalidate() {
    _checkOpen();
    _scheduler.request();
    _publishState();
  }

  /// Discards temporal samples after a camera cut, then requests a frame.
  void invalidateHistory() {
    _checkOpen();
    _engine?.invalidateHistory();
    invalidate();
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

  /// Replaces the requested plugin graph, including during initialization.
  /// Errors are returned and published to [issues] and [pluginIssue]. They do
  /// not tear down the session. Inspect [pluginIds], then call again to retry.
  Future<void> setPlugins(List<ScenePlugin> plugins) {
    _checkOpen();
    if (SceneEngine.inPluginHook) {
      return Future.error(
        StateError('Update controller plugins outside engine hooks.'),
      );
    }
    final desired = List<ScenePlugin>.of(plugins);
    _plugins
      ..clear()
      ..addAll(desired);
    final result = _pluginSync.then((_) async {
      await _initialization;
      _checkOpen();
      try {
        if (_status.value case SceneFailed(:final issue) when _engine == null) {
          throw SceneException(issue);
        }
        await _engine?.updatePlugins(desired);
        _pluginIssue = null;
        invalidate();
      } catch (error) {
        if (!_closed) {
          _pluginIssue = SceneIssue(
            code: 'plugin.updateFailed',
            message: error.toString(),
            operation: 'plugins',
            cause: error,
          );
          _issues.add(_pluginIssue!);
          _publishState();
        }
        rethrow;
      }
    });
    _pluginSync = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Retries the last desired graph after a recoverable plugin failure.
  Future<void> retryPlugins() => setPlugins(List.of(_plugins));

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
    _previousPresentation = null;
    _input.suspend();
    _input.viewport = const ViewportMetrics(0, 0);
    _viewToken = null;
    _viewLabel = null;
    _logicalSize = Size.zero;
    _input.setActive(false);
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
    final ready =
        _engine != null &&
        (_status.value is SceneReady || _status.value is SceneSuspended);
    _input.setActive(value && ready && !_closed);
    _scheduler.setVisible(value);
    if (_visible == value) return;
    _previousPresentation = null;
    _visible = value;
    if (_closed || !ready) return;
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
        onIssue: (issue) {
          if (!_closed && generation == _generation) _issues.add(issue);
        },
        acquireFrameDemand: _scheduler.acquireDemand,
        backendFactory: () async {
          final backend = await runtime.createBackend();
          if (_closed || generation != _generation) {
            await backend.close();
            throw _exception(
              SceneIssueCodes.disposed,
              'Controller closed during backend creation.',
              'initialize',
            );
          }
          final shared =
              options.presentation != PresentationPolicy.readbackOnly &&
              backend.capabilities.supports(RenderFeature.sharedTexture) &&
              (runtime.surfacePresenterFactory?.supports(backend) ?? false);
          final nativeView =
              options.presentation != PresentationPolicy.readbackOnly &&
              options.presentation != PresentationPolicy.requireSharedTexture &&
              backend.capabilities.supports(RenderFeature.nativeView) &&
              (runtime.nativeViewPresenterFactory?.supports(backend) ?? false);
          if (!shared &&
              !nativeView &&
              (options.presentation ==
                      PresentationPolicy.requireSharedTexture ||
                  options.presentation == PresentationPolicy.requireNative)) {
            await backend.close();
            throw _exception(
              SceneIssueCodes.presentationUnavailable,
              'The required native presentation path is unavailable. Select a supported runtime or enable readback explicitly.',
              'initialize',
            );
          }
          if (!shared &&
              !nativeView &&
              !backend.capabilities.supports(RenderFeature.rgbaReadback)) {
            await backend.close();
            throw _exception(
              SceneIssueCodes.unsupportedFeature,
              'The selected backend does not support RGBA readback.',
              'initialize',
            );
          }
          _backend = backend;
          _info = RendererInfo(
            backend: backend.capabilities.backend ?? backend.capabilities.name,
            adapterName: backend.capabilities.adapterName,
            driverDescription: backend.capabilities.driverDescription,
            capabilities: backend.capabilities,
            presentationPath: nativeView
                ? PresentationPath.nativeView
                : shared
                ? PresentationPath.sharedTexture
                : PresentationPath.readback,
          );
          return backend;
        },
      );
      if (_closed || generation != _generation) {
        await engine.dispose();
        return;
      }
      _engine = engine;
      _engine!.camera = camera;
      _pluginIssue = null;
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
    _input.setActive(false);
    _scheduler.setVisible(false);
    _clearStats();
    _status.value = SceneFailed(_generation, exception.issue);
    _issues.add(exception.issue);
    final failedEngine = _engine;
    _engine = null;
    if (failedEngine != null) {
      _failureCleanup = Future<void>.microtask(() async {
        await _drawing;
        await _closePresentation?.call();
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

  Future<FrameOutput> _render(
    FrameTime time,
    PhysicalSize size,
    OutputTarget target,
  ) {
    final completer = Completer<FrameOutput>();
    final logicalSize = _logicalSize, dpr = _devicePixelRatio;
    final aspect = logicalSize.width / logicalSize.height;
    _drawing = Future<void>.microtask(() async {
      try {
        _checkOpen();
        for (final entry in List.of(_updates.entries)) {
          if (_closed) break;
          if (_updates.containsKey(entry.key)) entry.value(time);
        }
        _checkOpen();
        await _pluginSync;
        _checkOpen();
        final frame = await _engine!.renderFrame(
          colorPipeline: _colorPipeline,
          target: target,
          elapsed: time.elapsed,
          time: time,
          aspectRatio: aspect,
          width: size.width,
          height: size.height,
        );
        final source = frame.stats.source;
        completer.complete(
          source == null
              ? frame
              : frame.withStats(
                  frame.stats.withSource(
                    source.withViewport(
                      logicalWidth: logicalSize.width,
                      logicalHeight: logicalSize.height,
                      devicePixelRatio: dpr,
                    ),
                  ),
                ),
        );
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  void _presented(FrameStats stats) {
    if (_closed) return;
    if (_presentations.hasListener) {
      final elapsed = _presentationClock.elapsed;
      _presentations.add(
        PresentationSample(
          frame: stats,
          elapsed: elapsed,
          interval: _previousPresentation == null
              ? null
              : elapsed - _previousPresentation!,
        ),
      );
      _previousPresentation = elapsed;
    }
    _latestFrameStats = stats;
    _publishState();
    if (!_firstFrame.isCompleted) _firstFrame.complete(stats);
    _pendingStats = stats;
    if (_statsTimer == null) _publishStats();
  }

  void _publishStats() {
    _statsTimer = null;
    final latest = _pendingStats;
    _pendingStats = null;
    if (_closed || latest == null) return;
    _stats.add(latest);
    _statsTimer = Timer(const Duration(milliseconds: 200), _publishStats);
  }

  void _clearStats() {
    _previousPresentation = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _pendingStats = null;
    _latestFrameStats = null;
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
      _backend = null;
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
    _clearStats();
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
      () => _pluginSync,
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
    _backend = null;
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
    _status.removeListener(_publishState);
    _state.close();
    unawaited(_issues.close());
    unawaited(_stats.close());
    unawaited(_presentations.close());
  }
}
