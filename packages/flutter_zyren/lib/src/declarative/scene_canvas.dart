import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:zyren/zyren.dart';
import '../controller/scene_controller.dart';
import '../controller/scene_runtime.dart';
import '../input/flutter_input_adapter.dart';
import 'scene_specs.dart';

export 'scene_specs.dart';
export 'scene_assets.dart';
export 'scene_selector.dart';
part 'scene_nodes.dart';
part 'scene_events.dart';
part 'scene_plugins.dart';

/// A native viewport with a declarative scene tree and an optional Flutter overlay.
/// You can compose scene children with ordinary StatelessWidget/StatefulWidget
/// components. Put visible Flutter controls in [overlay].
class SceneCanvas extends StatefulWidget {
  final List<Widget> children;
  final Widget? overlay;
  final SceneCamera camera;
  final Color3? background;
  final EngineOptions options;
  final SceneRuntime? runtime;

  /// Optional caller-owned cache. The canvas disposes only its default cache.
  final AssetCache? assetCache;
  final bool orbitControls;
  final List<ScenePlugin> plugins;
  final void Function(OrbitControls)? configureOrbitControls;
  final bool orbitKeyboard;
  final OrbitBehavior orbitBehavior;
  final void Function(SceneController controller)? onCreated;
  final SceneLoadingBuilder? loadingBuilder;
  final SceneErrorBuilder? errorBuilder;
  final void Function(SceneIssue issue)? onError;
  final double resolutionScale;

  /// A click with no registered event target, even if geometry was intersected.
  /// Navigation can own the pointer. Blocked overlays suppress this callback.
  final ScenePointerCallback? onPointerMissed;

  const SceneCanvas({
    super.key,
    this.children = const [],
    this.overlay,
    this.camera = const SceneCamera.perspective(),
    this.background,
    this.options = const EngineOptions(),
    this.runtime,
    this.assetCache,
    this.orbitControls = false,
    this.plugins = const [],
    this.configureOrbitControls,
    this.orbitKeyboard = false,
    this.orbitBehavior = OrbitBehavior.stdlib236,
    this.onCreated,
    this.loadingBuilder,
    this.errorBuilder,
    this.onError,
    this.resolutionScale = 1,
    this.onPointerMissed,
  });

  @override
  State<SceneCanvas> createState() => _SceneCanvasState();
}

class _SceneCanvasState extends State<SceneCanvas> {
  late final AssetCache assetCache;
  SceneController? _controller;
  SceneController get controller => _controller!;
  Object? _creationError;
  final _pluginNodes = <Object, ScenePlugin>{};
  List<ScenePlugin> _imperativePlugins = const [];
  OrbitControlsPlugin? _orbitPlugin;
  bool _pluginSyncPending = false;
  List<ScenePlugin>? _lastDesiredPlugins;
  late final _SceneEventDispatcher events;

  @override
  void initState() {
    super.initState();
    assetCache = widget.assetCache ?? AssetCache();
    try {
      _controller = SceneController(
        camera: widget.camera.create(),
        scene: Scene()..background = widget.background,
        options: widget.options,
        runtime: widget.runtime,
      );
      events = _SceneEventDispatcher(
        controller,
        (event) => widget.onPointerMissed?.call(event),
        () => widget.onPointerMissed != null,
      );
      widget.onCreated?.call(controller);
      _imperativePlugins = controller.requestedPlugins;
      _updateOrbitPlugin();
      _schedulePlugins();
    } catch (error) {
      _controller?.dispose();
      _creationError = error;
    }
  }

  @override
  void didUpdateWidget(SceneCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    events._syncInterests();
    if (widget.assetCache != oldWidget.assetCache ||
        widget.runtime != oldWidget.runtime ||
        _sessionOptions(widget.options) != _sessionOptions(oldWidget.options)) {
      throw FlutterError(
        'SceneCanvas runtime, options and assetCache configure its session. '
        'Keep them stable, or give SceneCanvas a new Key to start a new session.',
      );
    }
    if (widget.orbitKeyboard != oldWidget.orbitKeyboard ||
        widget.orbitBehavior != oldWidget.orbitBehavior) {
      _orbitPlugin = null;
    }
    _updateOrbitPlugin();
    if (widget.configureOrbitControls != oldWidget.configureOrbitControls &&
        _orbitPlugin?.controls != null) {
      widget.configureOrbitControls?.call(_orbitPlugin!.controls!);
      _orbitPlugin!.controls!.update();
      controller.invalidate();
    }
    _schedulePlugins();
    if (widget.camera != oldWidget.camera) {
      controller.camera = widget.camera.create();
    }
    if (widget.background != oldWidget.background) {
      controller.scene.background = widget.background;
    }
  }

  void _updateOrbitPlugin() {
    if (!widget.orbitControls) return;
    _orbitPlugin ??= OrbitControlsPlugin(
      configure: (controls) => widget.configureOrbitControls?.call(controls),
      keyboard: widget.orbitKeyboard,
      behavior: widget.orbitBehavior,
    );
  }

  void _registerPlugin(Object token, ScenePlugin? plugin) {
    if (plugin == null) {
      _pluginNodes.remove(token);
    } else {
      _pluginNodes[token] = plugin;
    }
    _schedulePlugins();
  }

  void _schedulePlugins() {
    if (_pluginSyncPending) return;
    _pluginSyncPending = true;
    scheduleMicrotask(() {
      _pluginSyncPending = false;
      if (!mounted || _controller == null || controller.isDisposed) return;
      // Collect the whole tree before dependency validation, regardless of order.
      final desired = <ScenePlugin>[
        ..._imperativePlugins,
        ...widget.plugins,
        if (widget.orbitControls) _orbitPlugin!,
        ..._pluginNodes.values,
      ];
      final previous = _lastDesiredPlugins;
      if (previous != null &&
          previous.length == desired.length &&
          List.generate(
            desired.length,
            (i) => i,
          ).every((i) => identical(previous[i], desired[i]))) {
        return;
      }
      _lastDesiredPlugins = desired;
      controller
          .setPlugins(desired)
          .then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {
              if (!mounted || controller.isDisposed) return;
              final issue = controller.pluginIssue;
              if (issue != null) widget.onError?.call(issue);
            },
          );
    });
  }

  static Object _sessionOptions(EngineOptions value) => (
    value.renderMode,
    value.presentation,
    value.recovery,
    value.maxFramesPerSecond,
    value.maxFramesInFlight,
  );

  @override
  void dispose() {
    if (_controller != null) events.dispose();
    _controller?.dispose();
    if (widget.assetCache == null) assetCache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_creationError != null) throw _creationError!;
    return _SceneHost(
      state: this,
      child: _SceneParent(
        object: controller.scene,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Offstage(child: _SceneChildren(children: widget.children)),
            MouseRegion(
              onExit: (_) => events.exit(),
              child: SceneView(
                controller: controller,
                resolutionScale: widget.resolutionScale,
                loadingBuilder: widget.loadingBuilder,
                errorBuilder: widget.errorBuilder,
                onError: widget.onError,
              ),
            ),
            if (widget.overlay != null) widget.overlay!,
          ],
        ),
      ),
    );
  }
}

/// Access the controller from a scene component or canvas overlay.
abstract final class SceneScope {
  static Future<void> retryPlugins(BuildContext context) =>
      of(context).retryPlugins();
  static AssetCache assetCacheOf(BuildContext context) =>
      _SceneHost.of(context).assetCache;
  static SceneController of(BuildContext context) =>
      _SceneHost.of(context).controller;
}

class _SceneHost extends InheritedWidget {
  final _SceneCanvasState state;
  const _SceneHost({required this.state, required super.child});
  static _SceneCanvasState of(BuildContext context) {
    final host = context.dependOnInheritedWidgetOfExactType<_SceneHost>();
    if (host == null) {
      throw FlutterError(
        'Scene widgets require a SceneCanvas ancestor. '
        'Place MeshNode, GroupNode and SceneFrame inside SceneCanvas.children.',
      );
    }
    return host.state;
  }

  @override
  bool updateShouldNotify(_SceneHost oldWidget) => state != oldWidget.state;
}

class _SceneParent extends InheritedWidget {
  final Object3D object;
  const _SceneParent({required this.object, required super.child});
  @override
  bool updateShouldNotify(_SceneParent oldWidget) => object != oldWidget.object;
}

class _SceneChildren extends StatelessWidget {
  final List<Widget> children;
  const _SceneChildren({required this.children});
  @override
  Widget build(BuildContext context) =>
      Column(mainAxisSize: MainAxisSize.min, children: children);
}

/// Runs outside Flutter build and releases continuous frame demand on removal.
class SceneFrame extends StatefulWidget {
  final void Function(SceneController controller, FrameTime time) onFrame;
  final bool enabled;
  final Widget child;
  const SceneFrame({
    super.key,
    required this.onFrame,
    this.enabled = true,
    this.child = const SizedBox.shrink(),
  });
  @override
  State<SceneFrame> createState() => _SceneFrameState();
}

class _SceneFrameState extends State<SceneFrame> {
  SceneController? _controller;
  Registration? _registration;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = SceneScope.of(context);
    if (next != _controller) {
      _registration?.dispose();
      _registration = null;
      _controller = next;
    }
    _sync();
  }

  void _sync() {
    if (_controller == null) return;
    if (!widget.enabled) {
      _registration?.dispose();
      _registration = null;
    } else {
      _registration ??= _controller!.onUpdate(
        (time) => widget.onFrame(_controller!, time),
      );
    }
  }

  @override
  void didUpdateWidget(SceneFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void deactivate() {
    _registration?.dispose();
    _registration = null;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    // didChangeDependencies binds the new canvas before another frame runs.
    _controller = null;
  }

  @override
  void dispose() {
    _registration?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
