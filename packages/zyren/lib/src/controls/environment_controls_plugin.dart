import '../input/pointer_event.dart';
import '../input/viewport_input.dart';
import '../plugins/engine.dart';
import 'environment_controls.dart';

/// Binds surface navigation to a viewport, including resize and camera changes.
class EnvironmentControlsPlugin extends ScenePlugin {
  @override
  String get id => 'zyren.environment-controls';
  final void Function(EnvironmentControls)? configure;
  EnvironmentControlsPlugin({this.configure});
  EnvironmentControls? _controls;
  EnvironmentControls? get controls => _controls;

  /// Override to supply a specialized surface controller through public APIs.
  EnvironmentControls createControls(PluginContext context) =>
      EnvironmentControls(
        context.camera,
        scene: context.scene,
        requestFrame: context.invalidate,
        viewport: context.input is ViewportInputSource
            ? (context.input as ViewportInputSource).viewport
            : const ViewportMetrics(1, 1),
      );

  void _bind(PluginContext context) {
    _controls?.dispose();
    final controls = createControls(context);
    _controls = controls;
    configure?.call(controls);
    controls.update(1 / 60);
  }

  void _sync(PluginContext context) {
    if (!identical(_controls?.camera, context.camera)) _bind(context);
    final input = context.input;
    if (input is ViewportInputSource) _controls!.viewport = input.viewport;
  }

  @override
  void attach(PluginContext context) {
    final input = context.input;
    if (input != null && input is! ViewportInputSource) {
      throw ArgumentError(
        'Surface navigation requires logical viewport dimensions.',
      );
    }
    _bind(context);
    if (input != null) {
      context.scope.keep(input.registerGesture(SceneGesture.pointerDrag));
      context.scope.keep(input.registerGesture(SceneGesture.scroll));
      context.scope.keep(
        InputRouter.forSource(input).register(
          id: id,
          priority: InputPriority.navigation,
          navigation: true,
          claims: (_) => true,
          onEvent: (event) {
            _sync(context);
            _controls!.handlePointer(event);
          },
        ),
      );
    }
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    _sync(context);
    // Surface height may change as geometry arrives even without user input.
    _controls!.update(
      frame.delta.inMicroseconds / Duration.microsecondsPerSecond,
    );
  }

  @override
  void detach(PluginContext context) {
    _controls?.dispose();
    _controls = null;
  }
}
