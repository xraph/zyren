part of 'clip.dart';

// Immutable ramps keep failed mixer updates from consuming transition time.
final class _AnimationRamp {
  final double from, to;
  final int duration, elapsed;
  final bool fresh, pauseWhenDone;
  const _AnimationRamp(
    this.from,
    this.to,
    this.duration, {
    this.elapsed = 0,
    this.fresh = true,
    this.pauseWhenDone = false,
  });

  int get remaining => duration - elapsed;
  _AnimationRamp reattach() => _AnimationRamp(
    from,
    to,
    duration,
    elapsed: elapsed,
    pauseWhenDone: pauseWhenDone,
  );
  double value(int time) =>
      time >= duration ? to : from + (to - from) * (time / duration);

  _AnimationRamp stepped(int micros) => _AnimationRamp(
    from,
    to,
    duration,
    elapsed: elapsed + math.min(micros, remaining),
    fresh: false,
    pauseWhenDone: pauseWhenDone,
  );

  // Each displacement is monotonic so a reversal cannot hide an endpoint.
  Iterable<double> displacements(int micros) sync* {
    final rampMicros = math.min(micros, remaining);
    if (rampMicros > 0) {
      final start = value(elapsed), end = value(elapsed + rampMicros);
      final seconds = rampMicros / 1e6;
      if ((start < 0 && end > 0) || (start > 0 && end < 0)) {
        final first = seconds * start / (start - end);
        yield start * first / 2;
        yield end * (seconds - first) / 2;
      } else {
        yield (start + end) * seconds / 2;
      }
    }
    if (micros > rampMicros) yield to * ((micros - rampMicros) / 1e6);
  }
}

void _advanceAnimation(
  _Playback state,
  int micros,
  double duration,
  bool fromFrame,
) {
  final fade = state.fade, warp = state.warp;
  final fadeMicros = fromFrame && (fade?.fresh ?? false) ? 0 : micros;
  final warpSkipped = fromFrame && (warp?.fresh ?? false);
  var clockMicros = state.paused || state.finished || (fromFrame && state.fresh)
      ? 0
      : micros;
  if (fade != null && fade.pauseWhenDone && fadeMicros >= fade.remaining) {
    clockMicros = math.min(clockMicros, fade.remaining);
  }
  if (clockMicros > 0) {
    if (warp != null && !warpSkipped) {
      for (final displacement in warp.displacements(clockMicros)) {
        state.advance(displacement, duration);
      }
    } else {
      state.advance(state.speed * (clockMicros / 1e6), duration);
    }
  }
  if (fade != null) {
    final next = fade.stepped(fadeMicros);
    state.weight = next.value(next.elapsed);
    state.fade = next.remaining == 0 ? null : next;
    if (next.remaining == 0 && next.pauseWhenDone) state.paused = true;
  }
  if (warp != null) {
    final next = warp.stepped(warpSkipped ? 0 : micros);
    state.speed = next.value(next.elapsed);
    state.warp = next.remaining == 0 ? null : next;
  }
  state.fresh = false;
}

int _transitionDuration(Duration duration) {
  if (duration.isNegative || duration.inMicroseconds > 1000000000000000) {
    throw ArgumentError.value(
      duration,
      'duration',
      'Use [0, 1000000000] seconds.',
    );
  }
  return duration.inMicroseconds;
}

void _fadeAnimation(
  _Playback state,
  double from,
  double to,
  int micros, {
  bool pauseWhenDone = false,
}) {
  state.weight = micros == 0 ? to : from;
  state.fade = micros == 0
      ? null
      : _AnimationRamp(from, to, micros, pauseWhenDone: pauseWhenDone);
  if (micros == 0 && pauseWhenDone) state.paused = true;
}

void _warpAnimation(_Playback state, double from, double to, int micros) {
  if (state.speed == 0) state.fresh = true;
  state.speed = micros == 0 ? to : from;
  state.warp = micros == 0 ? null : _AnimationRamp(from, to, micros);
}
