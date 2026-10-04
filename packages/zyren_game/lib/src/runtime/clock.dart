part of '../../zyren_game.dart';

/// Realtime admission only. Simulation time is always an integer tick.
final class GameClock {
  final int fixedHz, maxCatchUpSteps;
  double _accumulator = 0;
  int _pendingSteps = 0;
  double droppedSeconds = 0;
  double get stepSeconds => 1.0 / fixedHz;
  double get interpolation => (_accumulator / stepSeconds).clamp(0.0, 1.0);
  GameClock({this.fixedHz = 60, this.maxCatchUpSteps = 8}) {
    if (fixedHz < 1 || fixedHz > 240) {
      throw RangeError.range(fixedHz, 1, 240, 'fixedHz');
    }
    if (maxCatchUpSteps < 1 || maxCatchUpSteps > 64) {
      throw RangeError.range(maxCatchUpSteps, 1, 64, 'maxCatchUpSteps');
    }
  }
  int admit(double seconds) {
    _queue(seconds);
    final due = _pendingSteps;
    _pendingSteps = 0;
    return due;
  }

  void _queue(double seconds) {
    if (!seconds.isFinite || seconds < 0) {
      throw ArgumentError('Elapsed seconds must be finite and nonnegative.');
    }
    // Bound arithmetic before converting to an integer, even for huge deltas.
    final maxSeconds = maxCatchUpSteps * stepSeconds;
    final accepted = seconds > maxSeconds ? maxSeconds : seconds;
    droppedSeconds += seconds - accepted;
    _accumulator += accepted;
    final due = ((_accumulator + 1e-12) / stepSeconds).floor();
    _accumulator = (_accumulator - due * stepSeconds).clamp(0.0, stepSeconds);
    final queued = _pendingSteps + due;
    _pendingSteps = math.min(queued, maxCatchUpSteps);
    droppedSeconds += (queued - _pendingSteps) * stepSeconds;
  }

  void reset() {
    _accumulator = 0;
    _pendingSteps = 0;
  }
}
