export 'viewport_input.dart' show ViewportInputSource, ViewportLogicalExtent;
import '../plugins/registration.dart';
import 'viewport_point.dart';

enum ScenePointerPhase {
  down,
  move,
  up,
  cancel,
  hover,
  scroll,
  tap,
  scaleStart,
  scaleUpdate,
  scaleEnd,
}

enum ScenePointerKind {
  touch,
  mouse,
  stylus,
  invertedStylus,
  trackpad,
  unknown,
}

enum SceneModifier { shift, control, alt, meta }

enum SceneGesture { tap, scale, scroll, pointerDrag }

/// Pointer observations use logical units. Scale and rotation come from a won
/// Flutter gesture; rotation is in radians and scale starts at one.
final class ScenePointerEvent {
  final ViewportPoint point, delta;
  final ScenePointerPhase phase;
  final ScenePointerKind kind;
  final int pointer, buttons, pointerCount;
  final Set<SceneModifier> modifiers;
  final Duration time;
  final double scale, rotation;
  ScenePointerEvent({
    required this.point,
    required this.phase,
    this.pointer = 0,
    this.buttons = 0,
    this.pointerCount = 1,
    this.kind = ScenePointerKind.unknown,
    Set<SceneModifier> modifiers = const {},
    this.time = Duration.zero,
    this.delta = const ViewportPoint(0, 0),
    this.scale = 1,
    this.rotation = 0,
  }) : modifiers = Set.unmodifiable(modifiers);
}

abstract interface class InputSource {
  Stream<ScenePointerEvent> get events;

  /// Interests participate in the host's gesture arena only while registered.
  Registration registerGesture(SceneGesture gesture);
}
