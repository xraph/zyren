import 'dart:math' as math;
import '../plugins/registration.dart';
import 'frame_submission.dart';

/// A monotonic clock that submits only dirty scenes or active frame demands.
/// Call tick only when the consumer has capacity to accept another frame.
class FrameScheduler {
  final double _intervalMicros;
  double? _deadline;
  final void Function()? onChanged;
  bool get needsFrame => _visible && (_dirty || _demands > 0);
  bool _dirty = true, _visible = true, _resuming = true;
  int _demands = 0, _index = 0;
  Duration? _start, _lastFrame, _lastTick;
  FrameScheduler({int maxFramesPerSecond = 60, this.onChanged})
    : _intervalMicros = _frameInterval(maxFramesPerSecond);
  void request() {
    _dirty = true;
    onChanged?.call();
  }

  Registration acquireDemand() {
    _demands++;
    onChanged?.call();
    return Registration(() {
      _demands--;
      onChanged?.call();
    });
  }

  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    if (visible) {
      _resuming = true;
      request();
    }
  }

  FrameTime? tick(Duration now) {
    if (now.isNegative || (_lastTick != null && now < _lastTick!)) {
      throw ArgumentError('Frame time must be nonnegative and monotonic.');
    }
    _lastTick = now;
    _start ??= now;
    if (!_visible || (!_dirty && _demands == 0)) return null;
    final rawDelta = _lastFrame == null ? Duration.zero : now - _lastFrame!;
    final nowMicros = now.inMicroseconds;
    // Vsync timestamps are rounded to whole microseconds. Keep the fractional
    // deadline rather than accumulating rounding error from the last frame.
    if (!_resuming && _deadline != null && nowMicros + .5 < _deadline!) {
      return null;
    }
    if (_resuming || _deadline == null) {
      _deadline = nowMicros + _intervalMicros;
    } else {
      final intervals = math.max(
        1,
        ((nowMicros + .5 - _deadline!) / _intervalMicros).floor() + 1,
      );
      _deadline = _deadline! + intervals * _intervalMicros;
    }
    final delta = _resuming
        ? Duration.zero
        : Duration(microseconds: rawDelta.inMicroseconds.clamp(0, 100000));
    _dirty = false;
    _resuming = false;
    _lastFrame = now;
    return FrameTime(
      elapsed: now - _start!,
      delta: delta,
      rawDelta: rawDelta,
      index: _index++,
    );
  }
}

double _frameInterval(int fps) {
  if (fps < 1 || fps > 1000000) {
    throw ArgumentError.value(fps, 'maxFramesPerSecond');
  }
  return 1000000 / fps;
}
