part of '../../zyren_game.dart';

/// Timestamps use one monotonic unit within a device connection.
final class GameInputEvent {
  final String deviceId, control;
  final double value;
  final int timestamp;
  final bool consumed;
  GameInputEvent({
    required String deviceId,
    required String control,
    required this.value,
    required this.timestamp,
    this.consumed = false,
  }) : deviceId = _id(deviceId),
       control = _id(control) {
    if (!value.isFinite || value.abs() > 1 || timestamp < 0) {
      throw ArgumentError('Invalid input value or timestamp.');
    }
  }
}

/// A controller receives only the actions accepted for this actor and tick.
final class GameIntent {
  final GameEntityHandle actor;
  final int tick, epoch;
  final Map<String, double> actions;
  GameIntent({
    required this.actor,
    required this.tick,
    required this.epoch,
    required Map<String, double> actions,
  }) : actions = Map.unmodifiable(actions) {
    if (tick < 0 || epoch < 0 || actions.length > 128) {
      throw ArgumentError('Invalid intent envelope.');
    }
    for (final entry in actions.entries) {
      _id(entry.key);
      if (!entry.value.isFinite || entry.value.abs() > 1) {
        throw ArgumentError('Invalid intent action.');
      }
    }
  }
}
