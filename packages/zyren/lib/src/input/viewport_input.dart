import '../plugins/registration.dart';
import 'pointer_event.dart';

/// Logical dimensions are independent of render resolution and device pixels.
final class ViewportMetrics {
  final double width, height, devicePixelRatio;
  const ViewportMetrics(this.width, this.height, {this.devicePixelRatio = 1});
  bool get isUsable =>
      width.isFinite && height.isFinite && width > 0 && height > 0;
  double get aspect => width / height;
}

/// Optional host capability. Headless inputs can supply their own dimensions.
abstract interface class ViewportInputSource implements InputSource {
  ViewportMetrics get viewport;
}

enum SceneKey {
  arrowLeft,
  arrowUp,
  arrowRight,
  arrowDown,
  w,
  a,
  s,
  d,
  q,
  e,
  escape,
  space,
  tab,
  enter,
}

enum SceneKeyPhase { down, repeat, up, cancel }

final class SceneKeyEvent {
  final SceneKey key;
  final SceneKeyPhase phase;
  final Set<SceneModifier> modifiers;
  final Duration time;
  SceneKeyEvent(
    this.key,
    this.phase, {
    Set<SceneModifier> modifiers = const {},
    this.time = Duration.zero,
  }) : modifiers = Set.unmodifiable(modifiers);
}

/// Keys are routed only while the view owns focus and a consumer claims them.
abstract interface class KeyboardInputSource implements InputSource {
  Stream<SceneKeyEvent> get keyEvents;
  Registration registerKeys(Set<SceneKey> keys);
}

extension ViewportLogicalExtent on ViewportInputSource {
  double get logicalWidth => viewport.width;
  double get logicalHeight => viewport.height;
}

/// Optional focus lifecycle, including loss when no key is currently pressed.
abstract interface class FocusInputSource implements InputSource {
  bool get hasFocus;
  Stream<bool> get focusChanges;
}
