import 'package:zyren/zyren.dart';

/// Standards label time; conversion between them requires an explicit provider.
enum GeoTimeStandard { utc, tai, tt }

final class GeoInstant {
  final int tick, hz, generation;
  final DateTime epoch;
  final GeoTimeStandard standard;
  GeoInstant({
    required this.tick,
    required this.hz,
    required this.epoch,
    this.generation = 0,
    this.standard = GeoTimeStandard.utc,
  }) {
    if (tick < 0 ||
        tick > 9007199254740991 ||
        hz < 1 ||
        hz > 1000000 ||
        generation < 0 ||
        !epoch.isUtc) {
      throw ArgumentError(
        'Use a nonnegative bounded tick, positive rate and UTC-formatted epoch.',
      );
    }
  }
  double get seconds => tick / hz;
  GeoInstant withTick(int tick) => GeoInstant(
    tick: tick,
    hz: hz,
    epoch: epoch,
    generation: generation,
    standard: standard,
  );
  bool sameTimeline(GeoInstant other) =>
      hz == other.hz &&
      epoch == other.epoch &&
      generation == other.generation &&
      standard == other.standard;
  @override
  bool operator ==(Object other) =>
      other is GeoInstant && sameTimeline(other) && tick == other.tick;
  @override
  int get hashCode => Object.hash(tick, hz, epoch, generation, standard);
}

/// Integer tick admission from delta durations. Rendering never calls this clock.
final class GeoSimulationClock {
  final int hz, maxCatchUpSteps;
  final DateTime epoch;
  final GeoTimeStandard standard;
  int _tick = 0, _generation = 0, _droppedTicks = 0;
  int _numerator = 1, _denominator = 1;
  BigInt _accumulator = BigInt.zero;
  bool _paused = false;
  Object? _owner;
  GeoSimulationClock({
    this.hz = 60,
    this.maxCatchUpSteps = 8,
    DateTime? epoch,
    this.standard = GeoTimeStandard.utc,
  }) : epoch = epoch ?? DateTime.utc(1970) {
    GeoInstant(tick: 0, hz: hz, epoch: this.epoch, standard: standard);
    if (maxCatchUpSteps < 1 || maxCatchUpSteps > 10000) {
      throw ArgumentError('Catchup limit must be in [1, 10000].');
    }
  }
  int get tick => _tick;
  int get droppedTicks => _droppedTicks;
  double get interpolation =>
      _accumulator.toDouble() / (1000000 * _denominator);
  double get droppedSeconds => _droppedTicks / hz;
  GeoInstant get instant => GeoInstant(
    tick: tick,
    hz: hz,
    epoch: epoch,
    generation: _generation,
    standard: standard,
  );
  bool get paused => _paused;
  set paused(bool value) {
    if (_paused == value) return;
    _paused = value;
    _accumulator = BigInt.zero;
  }

  void setRate({required int numerator, required int denominator}) {
    if (numerator < 0 ||
        numerator > 1000000 ||
        denominator < 1 ||
        denominator > 1000000) {
      throw ArgumentError(
        'Clock rate must use bounded nonnegative rational values.',
      );
    }
    if (numerator == _numerator && denominator == _denominator) return;
    _numerator = numerator;
    _denominator = denominator;
    _accumulator = BigInt.zero;
  }

  int advance(Duration elapsed) {
    _unleased();
    final count = _admit(elapsed);
    for (var i = 0; i < count; i++) {
      _step();
    }
    return count;
  }

  void step() {
    _unleased();
    _step();
  }

  void _step() {
    instant.withTick(_tick + 1);
    _tick++;
  }

  void _unleased() {
    if (_owner != null) throw StateError('The clock has an active driver.');
  }

  int _admit(Duration elapsed, {int? maxSteps}) {
    if (elapsed.isNegative || elapsed > const Duration(days: 365)) {
      throw ArgumentError(
        'Elapsed delta must be in [0, 365 days]. Use replay restoration for seeking.',
      );
    }
    if (_paused) return 0;
    final cost = BigInt.from(1000000) * BigInt.from(_denominator);
    final total =
        _accumulator +
        BigInt.from(elapsed.inMicroseconds) *
            BigInt.from(hz) *
            BigInt.from(_numerator);
    final dueBig = total ~/ cost;
    if (dueBig > BigInt.from(9007199254740991 - _droppedTicks)) {
      throw ArgumentError('Elapsed delta exceeds bounded tick accounting.');
    }
    final due = dueBig.toInt();
    final limit = maxSteps == null || maxSteps > maxCatchUpSteps
        ? maxCatchUpSteps
        : maxSteps;
    if (limit < 1) throw ArgumentError('Admission limit must be positive.');
    final count = due > limit ? limit : due;
    if (_tick + count > 9007199254740991) {
      throw ArgumentError('Admitted ticks exceed the clock range.');
    }
    _accumulator = total % cost;
    _droppedTicks += due - count;
    return count;
  }

  GeoClockDriver acquireDriver(String owner) {
    _unleased();
    if (owner.trim().isEmpty) {
      throw ArgumentError('A clock driver needs an owner ID.');
    }
    final token = _owner = Object();
    return GeoClockDriver._(this, token, owner);
  }
}

final class GeoClockDriver extends Registration {
  final GeoSimulationClock _clock;
  final Object _token;
  final String owner;
  Object? _operation;
  GeoClockDriver._(this._clock, this._token, this.owner) : super(() {});
  GeoInstant get instant => _clock.instant;
  void _check({bool allowOperation = false}) {
    if (isDisposed || !identical(_clock._owner, _token)) {
      throw StateError('Clock driver has closed.');
    }
    if (!allowOperation && _operation != null) {
      throw StateError('The clock is reserved by an active advancement.');
    }
  }

  /// Reserves this clock while an asynchronous consumer finishes its ticks.
  GeoClockAdvance beginAdvance() {
    _check();
    final token = _operation = Object();
    return GeoClockAdvance._(this, token);
  }

  @override
  void dispose() {
    super.dispose();
    _finishClose();
  }

  void _finishClose() {
    if (isDisposed && _operation == null && identical(_clock._owner, _token)) {
      _clock._owner = null;
    }
  }

  int admit(Duration elapsed, {int? maxSteps}) {
    _check();
    return _clock._admit(elapsed, maxSteps: maxSteps);
  }

  void step() {
    _check();
    _clock._step();
  }

  int advance(Duration elapsed) {
    final due = admit(elapsed);
    for (var i = 0; i < due; i++) {
      step();
    }
    return due;
  }

  void beginReplay(GeoInstant checkpoint) {
    _check();
    if (checkpoint.hz != _clock.hz ||
        checkpoint.epoch != _clock.epoch ||
        checkpoint.standard != _clock.standard ||
        checkpoint.generation <= _clock._generation) {
      throw ArgumentError(
        'Replay requires the same clock standard and a newer generation.',
      );
    }
    _clock._tick = checkpoint.tick;
    _clock._generation = checkpoint.generation;
    _clock._accumulator = BigInt.zero;
  }
}

/// Exclusive admission and stepping within one asynchronous advancement.
final class GeoClockAdvance extends Registration {
  final GeoClockDriver _driver;
  final Object _token;
  GeoClockAdvance._(this._driver, this._token)
    : super(() {
        if (identical(_driver._operation, _token)) {
          _driver._operation = null;
          _driver._finishClose();
        }
      });

  GeoInstant get instant => _driver.instant;
  void _check() {
    _driver._check(allowOperation: true);
    if (isDisposed || !identical(_driver._operation, _token)) {
      throw StateError('Clock advancement has closed.');
    }
  }

  int admit(Duration elapsed, {int? maxSteps}) {
    _check();
    return _driver._clock._admit(elapsed, maxSteps: maxSteps);
  }

  void step() {
    _check();
    _driver._clock._step();
  }
}
