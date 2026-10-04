part of '../../zyren_game.dart';

/// One timer owner for the existing fixed clock. Rendering never drives this
/// session while the owner is attached. Catch-up steps yield between callbacks.
final class GameRealtimeClock {
  final GameSession session;
  final Duration Function() _elapsed;
  final void Function(Object error, StackTrace stack)? onError;
  final _measurements = StreamController<GameClockWake>.broadcast(sync: true);
  Stream<GameClockWake> get measurements => _measurements.stream;
  late final GameEventSubscription _state;
  Timer? _timer;
  bool _active = false, _closed = false, _waking = false, _running = false;
  int _epoch = -1;
  Duration _previous = Duration.zero, _scheduled = Duration.zero;
  int wakeCount = 0, advancedSteps = 0, maximumLatenessMicros = 0;
  bool get running => _running;
  bool get isClosed => _closed;

  GameRealtimeClock(this.session, {Duration Function()? elapsed, this.onError})
    : _elapsed = elapsed ?? (Stopwatch()..start()).elapsedGetter {
    session._requireOpen();
    if (session._realtimeClock != null) {
      throw StateError('The session already has a realtime clock owner.');
    }
    _state = session.listenState(_sync);
    session._realtimeClock = this;
  }

  /// Host visibility, independent of keyboard focus and explicit game pause.
  void setActive(bool value) {
    if (_closed) return;
    if (_active == value) return;
    _active = value;
    if (!value && _running && !session.isClosed) {
      session.invalidatePending();
    }
    _sync();
  }

  void _sync() {
    if (_closed) return;
    final allowed =
        _active &&
        !session.paused &&
        !session.isClosed &&
        !session.isRestoring &&
        !session._manualStepping &&
        session.fault == null;
    if (!allowed || _epoch != session.epoch) {
      _timer?.cancel();
      _timer = null;
      session.clock.reset();
      _running = false;
    }
    _epoch = session.epoch;
    if (!allowed) return;
    if (!_running) {
      _previous = _elapsed();
      _running = true;
    }
    if (!_waking && _timer == null) _schedule();
  }

  void _schedule() {
    if (!_running || _closed) return;
    final clock = session.clock;
    final now = _elapsed();
    final sinceAdmission = (now - _previous).inMicroseconds / 1000000;
    final remaining = clock._pendingSteps > 0
        ? 0.0
        : clock.stepSeconds - clock._accumulator - sinceAdmission;
    final delay = Duration(
      microseconds: math.max(0, (remaining * 1000000).ceil()),
    );
    _scheduled = now + delay;
    _timer = Timer(delay, _wake);
  }

  void _wake() {
    _timer = null;
    if (_closed) return;
    // An explicit invalidation can change the epoch without a state notification.
    if (_epoch != session.epoch) {
      _sync();
      return;
    }
    if (!_running) return;
    final now = _elapsed();
    final delta = now - _previous;
    final lateness = math.max(0, (now - _scheduled).inMicroseconds);
    _previous = now;
    _waking = true;
    var advanced = false;
    try {
      session.clock._queue(delta.inMicroseconds / 1000000);
      if (session.clock._pendingSteps > 0) {
        session.clock._pendingSteps--;
        final before = session.tick;
        session._step();
        advanced = session.tick != before;
      }
      wakeCount++;
      if (advanced) advancedSteps++;
      maximumLatenessMicros = math.max(maximumLatenessMicros, lateness);
      if (!_closed && _measurements.hasListener) {
        _measurements.add(
          GameClockWake(
            elapsed: now,
            latenessMicros: lateness,
            advanced: advanced,
            pendingSteps: session.clock._pendingSteps,
            droppedSeconds: session.droppedSeconds,
          ),
        );
      }
    } catch (error, stack) {
      if (!session.isClosed && session.fault == null) session._fail(error);
      onError?.call(error, stack);
    } finally {
      _waking = false;
      _sync();
    }
  }

  void dispose() {
    if (_closed) return;
    setActive(false);
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _state.cancel();
    if (identical(session._realtimeClock, this)) session._realtimeClock = null;
    unawaited(_measurements.close());
  }
}

final class GameClockWake {
  final Duration elapsed;
  final int latenessMicros, pendingSteps;
  final bool advanced;
  final double droppedSeconds;
  const GameClockWake({
    required this.elapsed,
    required this.latenessMicros,
    required this.advanced,
    required this.pendingSteps,
    required this.droppedSeconds,
  });
}

extension on Stopwatch {
  Duration elapsedGetter() => elapsed;
}
