// Nonnullable constructor parameters keep the two ownership modes explicit.
// ignore_for_file: prefer_initializing_formals
part of '../controller/scene_controller.dart';

typedef SceneLoadingBuilder = Widget Function(BuildContext context);
typedef SceneErrorBuilder =
    Widget Function(BuildContext context, SceneIssue issue, VoidCallback retry);

/// Displays one borrowed controller, or owns one controller in builder mode.
class SceneView extends StatefulWidget {
  final SceneController? controller;
  final Scene? _scene;
  final Camera? _camera;
  final Object? sceneKey;
  final void Function(SceneController)? onCreate;
  final EngineOptions options;
  final SceneRuntime? runtime;
  final SceneLoadingBuilder? loadingBuilder;
  final SceneErrorBuilder? errorBuilder;
  final void Function(SceneIssue)? onError;
  final double resolutionScale;
  final ScenePointerCallback? onPointer;
  const SceneView({
    super.key,
    required SceneController controller,
    this.loadingBuilder,
    this.errorBuilder,
    this.resolutionScale = 1,
    this.onError,
    this.onPointer,
  }) : _scene = null,
       _camera = null,
       controller = controller,
       sceneKey = null,
       onCreate = null,
       options = const EngineOptions(),
       runtime = null;
  const SceneView.builder({
    super.key,
    this.sceneKey,
    required void Function(SceneController) onCreate,
    this.options = const EngineOptions(),
    this.runtime,
    this.loadingBuilder,
    this.errorBuilder,
    this.resolutionScale = 1,
    this.onError,
    this.onPointer,
  }) : _scene = null,
       _camera = null,
       controller = null,
       onCreate = onCreate;
  SceneView.scene({
    super.key,
    Object? sceneKey,
    required Scene scene,
    required Camera camera,
    List<ScenePlugin> plugins = const [],
    this.options = const EngineOptions(),
    this.runtime,
    this.loadingBuilder,
    this.errorBuilder,
    this.resolutionScale = 1,
    this.onError,
    this.onPointer,
  }) : _scene = scene,
       _camera = camera,
       controller = null,
       sceneKey = sceneKey ?? (scene, camera),
       onCreate = ((view) {
         for (final plugin in plugins) {
           view.use(plugin);
         }
       });
  @override
  State<SceneView> createState() => _SceneViewState();
}

class _SceneViewState extends State<SceneView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  final Object _token = Object();
  SceneController? _controller;
  OutputPresenter? _presenter;
  bool? _presentationSuspended;
  PresentedFrame? _frame;
  SceneIssue? _localIssue;
  SceneIssue? _notifiedIssue;
  Size _size = Size.zero;
  double _dpr = 1;
  bool _busy = false, _owns = false, _attached = false;
  int _version = 0;
  Future<void> _transition = Future.value();
  Future<void>? _drawing, _closingPresentation;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(
      (_) => _tick(SchedulerBinding.instance.currentSystemFrameTimeStamp),
    );
    _replace();
  }

  @override
  void didUpdateWidget(SceneView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        oldWidget.sceneKey != widget.sceneKey ||
        (oldWidget.onCreate == null) != (widget.onCreate == null)) {
      _replace();
    } else if (oldWidget.resolutionScale != widget.resolutionScale) {
      _validateScale();
      _controller?._scheduler.request();
    }
  }

  void _validateScale() {
    if (!widget.resolutionScale.isFinite || widget.resolutionScale <= 0) {
      throw ArgumentError('resolutionScale must be positive and finite.');
    }
  }

  void _replace() {
    _validateScale();
    final version = ++_version;
    final nextWidget = widget;
    _stopTicker();
    _transition = _transition
        .then((_) async {
          await _unbind();
          if (!mounted || version != _version) return;
          _localIssue = null;
          _notifiedIssue = null;
          _closingPresentation = null;
          _owns = nextWidget.controller == null;
          final controller =
              nextWidget.controller ??
              SceneController(
                scene: nextWidget._scene,
                camera: nextWidget._camera,
                options: nextWidget.options,
                runtime: nextWidget.runtime,
              );
          _controller = controller;
          try {
            if (_owns) nextWidget.onCreate!(controller);
            controller._attach(_token, 'SceneView#${identityHashCode(this)}');
            _attached = true;
            controller._logicalSize = _size;
            controller._wakeView = _sync;
            controller._input.onInterestsChanged = _onInterestsChanged;
            controller._closePresentation = _closePresentation;
            controller._status.addListener(_onStatus);
            _sync();
          } catch (error, stack) {
            _localIssue = _issue(error, 'attach');
            _notify(_localIssue!);
            if (_owns) {
              controller.dispose();
              await controller.whenDisposed;
            }
            if (error is! SceneException && error is! StateError) {
              _report(error, stack);
            }
          }
          if (mounted && version == _version) setState(() {});
        })
        .catchError((Object error, StackTrace stack) {
          _report(error, stack);
        });
  }

  SceneIssue _issue(Object error, String operation) => error is SceneException
      ? error.issue
      : SceneIssue(
          code: SceneIssueCodes.renderFailed,
          message: error.toString(),
          operation: operation,
          cause: error,
        );
  void _onInterestsChanged() {
    if (mounted) setState(() {});
  }

  void _onStatus() {
    final controller = _controller;
    if (!mounted || controller == null) return;
    final status = controller.status.value;
    if (status is SceneReady && _presenter == null) _closingPresentation = null;
    if (status case SceneFailed(:final issue)) {
      _notify(issue);
    }
    if (status is SceneDisposed) {
      unawaited(_closePresentation());
    }
    _sync();
    setState(() {});
  }

  void _notify(SceneIssue issue) {
    if (identical(_notifiedIssue, issue)) return;
    _notifiedIssue = issue;
    try {
      widget.onError?.call(issue);
    } catch (error, stack) {
      _report(error, stack);
    }
  }

  static void _report(Object error, StackTrace stack) =>
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'flutter_gpu3d',
          context: ErrorDescription('while operating a native scene view'),
        ),
      );
  static bool _visible(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;
  void _sync() {
    final controller = _controller;
    if (!_attached ||
        controller == null ||
        controller.isDisposed ||
        controller.status.value is SceneFailed) {
      _stopTicker();
      return;
    }
    final visible =
        !_size.isEmpty &&
        _visible(WidgetsBinding.instance.lifecycleState) &&
        TickerMode.valuesOf(context).enabled;
    controller._setVisible(visible);
    if (_presenter != null && _presentationSuspended != !visible) {
      _presentationSuspended = !visible;
      _presenter!.setSuspended(!visible).catchError((
        Object error,
        StackTrace stack,
      ) {
        if (mounted && !controller.isDisposed) {
          controller._fail(error, stack, 'surface');
        }
      });
    }
    if (!visible) {
      _stopTicker();
      return;
    }
    controller._start();
    if (controller._engine != null && controller._scheduler.needsFrame) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      _stopTicker();
    }
  }

  void _stopTicker() {
    if (_ticker.isActive) _ticker.stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _sync();
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dpr =
        MediaQuery.maybeDevicePixelRatioOf(context) ??
        View.of(context).devicePixelRatio;
    if (dpr != _dpr) {
      _dpr = dpr;
      _controller?._scheduler.request();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  void _tick(Duration now) {
    final controller = _controller;
    if (_busy ||
        !_attached ||
        controller == null ||
        controller.isDisposed ||
        _size.isEmpty ||
        controller._engine == null ||
        controller._retiring != null) {
      return;
    }
    final time = controller._scheduler.tick(now);
    if (time == null) return;
    final limit = controller._info!.capabilities.limits.maxTextureDimension2D;
    final ratio = math.min(
      _dpr * widget.resolutionScale,
      limit / math.max(_size.width, _size.height),
    );
    final size = PhysicalSize(
      math.max(1, (_size.width * ratio).round()),
      math.max(1, (_size.height * ratio).round()),
    );
    _busy = true;
    _drawing = _draw(controller, time, size, _version);
    if (!controller._scheduler.needsFrame) _stopTicker();
  }

  Future<void> _draw(
    SceneController controller,
    FrameTime time,
    PhysicalSize size,
    int version,
  ) async {
    try {
      if (_presenter == null) {
        _presenter = controller._createPresenter();
        if (_presenter is HostedOutputPresenter) setState(() {});
      }
      final target = await _presenter!.prepare(size);
      if (!mounted || version != _version || controller.isDisposed) return;
      final frame = await controller._render(time, size, target);
      if (!mounted || version != _version || controller.isDisposed) return;
      final next = await _presenter!.present(frame);
      if (!mounted || version != _version || controller.isDisposed) {
        _release(next);
        return;
      }
      final previous = _frame;
      setState(() => _frame = next);
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _release(previous));
      }
      controller._presented(frame.stats);
    } catch (error, stack) {
      if (mounted && version == _version && !controller.isDisposed) {
        if (error is SceneException &&
            error.issue.code == SceneIssueCodes.frameDeferred) {
          controller._scheduler.request();
        } else {
          controller._fail(error, stack, 'render');
        }
      }
    } finally {
      _busy = false;
      if (mounted && version == _version) _sync();
    }
  }

  void _release(PresentedFrame? frame) {
    try {
      frame?.dispose();
    } catch (error, stack) {
      _report(error, stack);
    }
  }

  Future<void> _closePresentation() =>
      _closingPresentation ??= Future<void>.microtask(() async {
        _stopTicker();
        final pending = _presenter;
        if (pending is HostedOutputPresenter) pending.cancelPending();
        await _drawing;
        final frame = _frame;
        _frame = null;
        _release(frame);
        final presenter = _presenter;
        _presenter = null;
        _presentationSuspended = null;
        await presenter?.dispose();
      });
  Future<void> _unbind() async {
    final previous = _controller;
    if (previous == null) return;
    if (_attached) {
      _attached = false;
      previous._status.removeListener(_onStatus);
      if (previous._input.onInterestsChanged == _onInterestsChanged) {
        previous._input.onInterestsChanged = null;
      }
      previous._detach(_token);
      if (_owns) previous.dispose();
      await _closePresentation();
      if (previous._closePresentation == _closePresentation) {
        previous._closePresentation = null;
      }
    }
    if (_owns) {
      previous.dispose();
      await previous.whenDisposed;
    }
    _controller = null;
  }

  @override
  void dispose() {
    _version++;
    WidgetsBinding.instance.removeObserver(this);
    _stopTicker();
    // Reject managed work now; the transition waits for resource cleanup.
    if (_attached) {
      _controller!._status.removeListener(_onStatus);
      _controller!._scheduler.setVisible(false);
      _controller!._detach(_token);
      if (_owns) _controller!.dispose();
    }
    _transition = _transition
        .then((_) => _unbind())
        .catchError((Object error, StackTrace stack) => _report(error, stack));
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
        _size = Size.zero;
        if (_attached) _controller?._logicalSize = Size.zero;
        return const Text('SceneView needs a bounded width and height.');
      }
      if (_size != constraints.biggest) {
        _size = constraints.biggest;
        if (_attached) _controller?._logicalSize = _size;
        _controller?._scheduler.request();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _sync();
        });
      }
      final status = _controller?.status.value;
      final issue =
          _localIssue ?? (status is SceneFailed ? status.issue : null);
      if (issue != null) {
        return widget.errorBuilder?.call(context, issue, () {
              unawaited(_retry());
            }) ??
            Center(child: Text(issue.message));
      }
      if (status is SceneDisposed) return const SizedBox.expand();
      final presenter = _presenter;
      final content =
          (presenter is HostedOutputPresenter
              ? presenter.build(context)
              : _frame?.build(context)) ??
          widget.loadingBuilder?.call(context) ??
          const SizedBox.expand();
      return SizedBox.expand(
        child: _controller?._input.wrap(content, widget.onPointer) ?? content,
      );
    },
  );
  Future<void> _retry() async {
    if (_localIssue != null) {
      _replace();
      return;
    }
    await _closePresentation();
    _closingPresentation = null;
    await _controller?.retry();
    if (mounted) _sync();
  }
}
