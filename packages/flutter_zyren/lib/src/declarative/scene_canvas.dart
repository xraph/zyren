import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:zyren/zyren.dart';
import '../controller/scene_controller.dart';
import '../controller/scene_runtime.dart';
import 'scene_specs.dart';

export 'scene_specs.dart';
part 'scene_nodes.dart';

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
  final bool orbitControls;
  final void Function(SceneController controller)? onCreated;
  final SceneLoadingBuilder? loadingBuilder;
  final SceneErrorBuilder? errorBuilder;
  final void Function(SceneIssue issue)? onError;
  final double resolutionScale;

  const SceneCanvas({
    super.key,
    this.children = const [],
    this.overlay,
    this.camera = const SceneCamera.perspective(),
    this.background,
    this.options = const EngineOptions(),
    this.runtime,
    this.orbitControls = false,
    this.onCreated,
    this.loadingBuilder,
    this.errorBuilder,
    this.onError,
    this.resolutionScale = 1,
  });

  @override
  State<SceneCanvas> createState() => _SceneCanvasState();
}

class _SceneCanvasState extends State<SceneCanvas> {
  SceneController? _controller;
  SceneController get controller => _controller!;
  Object? _creationError;
  final taps = <Object3D, void Function(PickResult)>{};
  Registration? _tapInterest;
  bool _tapSyncPending = false;

  @override
  void initState() {
    super.initState();
    try {
      _controller = SceneController(
        camera: widget.camera.create(),
        scene: Scene()..background = widget.background,
        options: widget.options,
        runtime: widget.runtime,
      );
      if (widget.orbitControls) controller.use(OrbitControlsPlugin());
      widget.onCreated?.call(controller);
    } catch (error) {
      _controller?.dispose();
      _creationError = error;
    }
  }

  @override
  void didUpdateWidget(SceneCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.runtime != oldWidget.runtime ||
        _sessionOptions(widget.options) != _sessionOptions(oldWidget.options) ||
        widget.orbitControls != oldWidget.orbitControls) {
      throw FlutterError(
        'SceneCanvas runtime, options and orbitControls configure its session. '
        'Keep them stable, or give SceneCanvas a new Key to start a new session.',
      );
    }
    if (widget.camera != oldWidget.camera) {
      controller.camera = widget.camera.create();
    }
    if (widget.background != oldWidget.background) {
      controller.scene.background = widget.background;
    }
  }

  static Object _sessionOptions(EngineOptions value) => (
    value.renderMode,
    value.presentation,
    value.recovery,
    value.maxFramesPerSecond,
    value.maxFramesInFlight,
  );

  void _setTap(Object3D object, void Function(PickResult)? callback) {
    if (callback == null) {
      taps.remove(object);
    } else {
      taps[object] = callback;
    }
    // SceneView is a sibling of the scene tree. Notify it after Flutter build.
    if (_tapSyncPending) return;
    _tapSyncPending = true;
    scheduleMicrotask(_syncTapInterest);
  }

  void _syncTapInterest() {
    _tapSyncPending = false;
    if (!mounted || controller.isDisposed) return;
    if (taps.isEmpty) {
      _tapInterest?.dispose();
      _tapInterest = null;
    } else if (_tapInterest == null && !controller.isDisposed) {
      _tapInterest = controller.input.registerGesture(SceneGesture.tap);
    }
  }

  void _onPointer(ScenePointerEvent event) {
    if (event.phase != ScenePointerPhase.tap || taps.isEmpty) return;
    controller
        .pick(event.point)
        .then((hit) {
          if (!mounted || controller.isDisposed || hit == null) return;
          // A queued pick cannot target an object removed before delivery.
          Object3D? root = hit.object;
          while (root?.parent != null) {
            root = root!.parent;
          }
          if (!identical(root, controller.scene)) return;
          for (
            Object3D? object = hit.object;
            object != null;
            object = object.parent
          ) {
            final callback = taps[object];
            if (callback != null) {
              callback(hit);
              break;
            }
          }
        })
        .catchError((Object error, StackTrace stack) {
          if (!mounted || controller.isDisposed) return;
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'flutter_zyren',
              context: ErrorDescription('while dispatching a scene tap'),
            ),
          );
        });
  }

  @override
  void dispose() {
    _tapInterest?.dispose();
    taps.clear();
    _controller?.dispose();
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
            SceneView(
              controller: controller,
              resolutionScale: widget.resolutionScale,
              loadingBuilder: widget.loadingBuilder,
              errorBuilder: widget.errorBuilder,
              onError: widget.onError,
              onPointer: _onPointer,
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
