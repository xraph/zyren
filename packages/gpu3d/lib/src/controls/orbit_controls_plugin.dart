import '../input/pointer_event.dart';
import '../input/viewport_input.dart';
import '../plugins/engine.dart';
import '../plugins/registration.dart';
import 'orbit_controls.dart';

/// Attaches one versioned orbit controller to a scene viewport.
/// Replacing the camera creates fresh controls and reapplies [configure].
class OrbitControlsPlugin extends ScenePlugin {
  @override
  String get id => 'gpu3d.orbit-controls';
  final void Function(OrbitControls)? configure;
  final bool keyboard;
  final OrbitBehavior behavior;
  OrbitControlsPlugin({
    this.configure,
    this.keyboard = false,
    this.behavior = OrbitBehavior.stdlib236,
  });
  OrbitControls? _controls;
  OrbitControls? get controls => _controls;
  PluginContext? _context;
  Registration? _keyInterest;
  int _seenRevision = -1;

  void _wake() => _context?.invalidate();
  void _bind(PluginContext context) {
    _keyInterest?.dispose();
    _keyInterest = null;
    _controls?.dispose();
    final input = context.input;
    final controls = OrbitControls(
      context.camera,
      behavior: behavior,
      target: context.camera.target,
      viewport: input is ViewportInputSource
          ? input.viewport
          : const ViewportMetrics(1, 1),
      requestFrame: _wake,
    );
    _controls = controls;
    configure?.call(controls);
    controls.update();
    _seenRevision = context.camera.revision;
    if (keyboard && input is KeyboardInputSource) {
      _keyInterest = input.registerKeys(controls.keys.keys.toSet());
    }
  }

  void _syncViewport() {
    final input = _context?.input;
    if (input is ViewportInputSource) _controls?.viewport = input.viewport;
  }

  @override
  void attach(PluginContext context) {
    if (context.input != null && context.input is! ViewportInputSource) {
      throw ArgumentError(
        'Orbit input must provide logical viewport dimensions.',
      );
    }
    _context = context;
    _bind(context);
    final input = context.input;
    if (input != null) {
      context.scope.keep(input.registerGesture(SceneGesture.pointerDrag));
      context.scope.keep(input.registerGesture(SceneGesture.scroll));
      context.scope.listen(input.events, (event) {
        if (!identical(_controls?.camera, context.camera)) _bind(context);
        _syncViewport();
        _controls!.handlePointer(event);
      });
      if (keyboard && input is KeyboardInputSource) {
        context.scope.listen(input.keyEvents, (event) {
          if (!identical(_controls?.camera, context.camera)) _bind(context);
          _syncViewport();
          _controls!.handleKey(event);
        });
      }
    }
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    if (!identical(_controls?.camera, context.camera)) _bind(context);
    _syncViewport();
    final controls = _controls!;
    if (controls.needsUpdate || _seenRevision != context.camera.revision) {
      controls.update(
        behavior == OrbitBehavior.three184
            ? frame.delta.inMicroseconds / Duration.microsecondsPerSecond
            : null,
      );
    }
    _seenRevision = context.camera.revision;
    if (controls.needsUpdate) context.invalidate();
  }

  @override
  void detach(PluginContext context) {
    _keyInterest?.dispose();
    _keyInterest = null;
    _controls?.dispose();
    _controls = null;
    _context = null;
  }
}
