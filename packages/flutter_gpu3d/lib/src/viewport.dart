import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'engine.dart';
import 'native_renderer.dart';
import 'presentation.dart';
import 'renderer.dart';
import 'scene.dart';

typedef FrameCallback = void Function(Duration elapsed);

/// Owns its engine, plugin lifecycle, presenter and displayed frames.
/// Changing factories, scene, camera or plugin instances rebuilds the engine.
class SceneView extends StatefulWidget {
  final Scene scene;
  final PerspectiveCamera camera;
  final RendererFactory rendererFactory;
  final PresenterFactory presenterFactory;
  final List<ScenePlugin> plugins;

  /// Change this value to retry initialization after an error.
  final Object? restartToken;
  final FrameCallback? onFrame;
  final void Function(Object error)? onError;
  final Widget Function(BuildContext context, Object error)? errorBuilder;
  final double pixelRatio;
  final int maxFramesPerSecond;
  const SceneView({
    super.key,
    required this.scene,
    required this.camera,
    this.rendererFactory = NativeRenderer.create,
    this.presenterFactory = ImageFramePresenter.create,
    this.plugins = const [],
    this.restartToken,
    this.onFrame,
    this.onError,
    this.errorBuilder,
    this.pixelRatio = 1,
    this.maxFramesPerSecond = 30,
  });
  @override
  State<SceneView> createState() => _SceneViewState();
}

class _ViewSession {
  final SceneEngine engine;
  final FramePresenter presenter;
  _ViewSession(this.engine, this.presenter);
  Future<void> dispose() async {
    final errors = <Object>[];
    try {
      await engine.dispose();
    } catch (error) {
      errors.add(error);
    }
    try {
      await presenter.dispose();
    } catch (error) {
      errors.add(error);
    }
    if (errors.isNotEmpty) throw EngineCleanupException(errors);
  }
}

class _SceneViewState extends State<SceneView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  _ViewSession? _session;
  PresentedFrame? _presented;
  Object? _error;
  late final Ticker _ticker;
  late List<ScenePlugin> _plugins;
  Size _size = Size.zero;
  bool _busy = false;
  Duration _last = Duration.zero;
  int _generation = 0;
  Future<void> _transition = Future.value();
  Future<void>? _drawing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_tick);
    _configure();
  }

  @override
  void didUpdateWidget(SceneView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.restartToken != oldWidget.restartToken ||
        !identical(widget.scene, oldWidget.scene) ||
        !identical(widget.camera, oldWidget.camera) ||
        widget.rendererFactory != oldWidget.rendererFactory ||
        widget.presenterFactory != oldWidget.presenterFactory ||
        _plugins.length != widget.plugins.length ||
        Iterable<int>.generate(
          _plugins.length,
        ).any((index) => !identical(_plugins[index], widget.plugins[index]))) {
      _configure();
    }
  }

  bool _current(int generation) => mounted && generation == _generation;

  // Serialize replacement with pending rendering and plugin teardown.
  void _configure() {
    final generation = ++_generation;
    _plugins = List.of(widget.plugins);
    final plugins = _plugins;
    final scene = widget.scene, camera = widget.camera;
    final rendererFactory = widget.rendererFactory;
    final presenterFactory = widget.presenterFactory;
    _ticker.stop();
    _last = Duration.zero;
    _error = null;
    _retire(_presented);
    _presented = null;
    _transition = _transition
        .then((_) async {
          final previous = _session;
          _session = null;
          await _drawing;
          await previous?.dispose();
          if (!_current(generation)) return;
          final engine = await SceneEngine.create(
            scene: scene,
            camera: camera,
            plugins: plugins,
            rendererFactory: rendererFactory,
          );
          FramePresenter presenter;
          try {
            presenter = presenterFactory();
          } catch (error, stack) {
            try {
              await engine.dispose();
            } catch (cleanupError) {
              throw EngineInitializationException(error, cleanupError);
            }
            Error.throwWithStackTrace(error, stack);
          }
          final session = _ViewSession(engine, presenter);
          if (!_current(generation)) {
            await session.dispose();
            return;
          }
          _session = session;
          if (_visible(WidgetsBinding.instance.lifecycleState)) _ticker.start();
        })
        .catchError((Object error, StackTrace stack) {
          if (_current(generation)) {
            _fail(error);
          } else {
            _reportCleanup(error, stack);
          }
        });
  }

  void _retire(PresentedFrame? frame) {
    if (frame == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _releaseFrame(frame));
  }

  static void _releaseFrame(PresentedFrame? frame) {
    try {
      frame?.dispose();
    } catch (error, stack) {
      _reportCleanup(error, stack);
    }
  }

  static void _reportCleanup(Object error, StackTrace stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'flutter_gpu3d',
        context: ErrorDescription('while releasing a native scene viewport'),
      ),
    );
  }

  // An inactive desktop window is still visible and must produce frames.
  static bool _visible(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  void _fail(Object error) {
    if (!mounted) return;
    _ticker.stop();
    setState(() {
      _error = error;
    });
    try {
      widget.onError?.call(error);
    } catch (callbackError, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: callbackError,
          stack: stack,
          library: 'flutter_gpu3d',
          context: ErrorDescription('while notifying a scene error observer'),
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_visible(state) && _session != null && _error == null) {
      _last = Duration.zero;
      if (!_ticker.isActive) _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    if (_busy || _size.isEmpty || _session == null) return;
    final fps = widget.maxFramesPerSecond.clamp(1, 120);
    if (elapsed - _last < Duration(microseconds: 1000000 ~/ fps)) return;
    _last = elapsed;
    _busy = true;
    _drawing = _draw(elapsed, _session!, _generation);
  }

  Future<void> _draw(
    Duration elapsed,
    _ViewSession session,
    int generation,
  ) async {
    try {
      if (!widget.pixelRatio.isFinite || widget.pixelRatio <= 0) {
        throw ArgumentError('pixelRatio must be positive.');
      }
      widget.onFrame?.call(elapsed);
      final ratio = math.min(
        widget.pixelRatio,
        session.engine.capabilities.maxDimension /
            math.max(_size.width, _size.height),
      );
      final frame = await session.engine.render(
        elapsed: elapsed,
        width: math.max(1, (_size.width * ratio).round()),
        height: math.max(1, (_size.height * ratio).round()),
      );
      if (!_current(generation)) return;
      final next = await session.presenter.present(frame);
      if (!_current(generation)) {
        _releaseFrame(next);
        return;
      }
      final previous = _presented;
      setState(() {
        _presented = next;
      });
      _retire(previous);
    } catch (error) {
      if (_current(generation)) _fail(error);
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _releaseFrame(_presented);
    _transition = _transition
        .then((_) async {
          await _drawing;
          await _session?.dispose();
          _session = null;
        })
        .catchError(_reportCleanup);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
        return const Text('SceneView needs a bounded width and height.');
      }
      _size = constraints.biggest;
      if (_error != null) {
        return widget.errorBuilder?.call(context, _error!) ??
            Center(child: Text('Native rendering failed: $_error'));
      }
      return _presented?.build(context) ?? const SizedBox.expand();
    },
  );
}
