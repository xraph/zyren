import 'time.dart';

/// Accepts ticks from a game or application clock without admitting wall time.
final class GeoExternalClock {
  GeoInstant? _instant;
  GeoInstant get instant =>
      _instant ?? (throw StateError('No external tick has been accepted.'));
  bool accept(GeoInstant value) {
    final previous = _instant;
    if (previous != null) {
      if (!value.sameTimeline(previous)) {
        throw StateError(
          'External clock timeline changed without replay restoration.',
        );
      }
      if (value.tick < previous.tick) {
        throw StateError('External ticks must not run backwards.');
      }
      if (value.tick == previous.tick) return false;
    }
    _instant = value;
    return true;
  }

  void beginReplay(GeoInstant checkpoint) {
    final previous = _instant;
    if (previous != null &&
        (checkpoint.generation <= previous.generation ||
            checkpoint.hz != previous.hz ||
            checkpoint.epoch != previous.epoch ||
            checkpoint.standard != previous.standard)) {
      throw ArgumentError(
        'Replay needs a new generation on the same external time standard.',
      );
    }
    _instant = checkpoint;
  }
}
