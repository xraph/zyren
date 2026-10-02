import 'package:zyren/rendering.dart';

/// A frame accepted by the presenter, after its presentation future completes.
/// This measures application pacing, not the display's physical scanout time.
final class PresentationSample {
  final FrameStats frame;

  /// Monotonic time since the controller was created.
  final Duration elapsed;

  /// Time since the preceding observed presentation. Null when observation
  /// begins, the view remounts or resumes, or the renderer recovers from failure.
  /// Idle time in an attached, visible demand-rendered view remains included.
  final Duration? interval;
  const PresentationSample({
    required this.frame,
    required this.elapsed,
    this.interval,
  });
}
