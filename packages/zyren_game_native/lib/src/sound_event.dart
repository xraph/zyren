part of '../zyren_game_native.dart';

/// Gameplay stimulus in world metres, independent of speaker playback state.
final class GameSoundEvent {
  final String id, category;
  final int tick;
  final String? sourceEntityId;
  final Vec3 position;
  final double loudness, range;
  GameSoundEvent({
    required this.id,
    required this.category,
    required this.tick,
    required this.position,
    required this.loudness,
    required this.range,
    this.sourceEntityId,
  }) {
    if (id.isEmpty ||
        id.length > 1024 ||
        category.isEmpty ||
        category.length > 128 ||
        tick < 0 ||
        sourceEntityId != null &&
            (sourceEntityId!.isEmpty || sourceEntityId!.length > 1024) ||
        !position.x.isFinite ||
        !position.y.isFinite ||
        !position.z.isFinite ||
        !loudness.isFinite ||
        loudness < 0 ||
        loudness > 1 ||
        !range.isFinite ||
        range <= 0 ||
        range > 100000) {
      throw ArgumentError('Invalid gameplay sound event.');
    }
  }
}

/// Sound receipts are deduplicated within the authoritative tick.
final class GameSoundPublisher {
  final GameSession session;
  final int capacity;
  int _tick = -1, _epoch = -1;
  final Set<String> _receipts = {};
  GameSoundPublisher(this.session, {this.capacity = 512}) {
    if (capacity < 1 || capacity > 4096) {
      throw ArgumentError('Invalid sound receipt capacity.');
    }
  }
  bool emit(GameSoundEvent event) {
    if (session.isClosed ||
        session.paused ||
        session.fault != null ||
        event.tick != session.tick ||
        !session.events.canEmit) {
      return false;
    }
    if (_tick != event.tick || _epoch != session.epoch) {
      _tick = event.tick;
      _epoch = session.epoch;
      _receipts.clear();
    }
    if (_receipts.length >= capacity || !_receipts.add(event.id)) return false;
    session.events.emit(event.tick, event);
    return true;
  }
}
