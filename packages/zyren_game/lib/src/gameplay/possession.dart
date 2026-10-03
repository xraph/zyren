part of '../../zyren_game.dart';

/// Wrap an adapter lease, including GameCharacterControlLease.dispose.
final class GamePossessionControl {
  final bool Function() _isActive;
  final void Function() _release;
  bool _released = false;
  GamePossessionControl({
    required bool Function() isActive,
    required void Function() release,
  }) : _isActive = isActive,
       _release = release;
  bool get isActive => !_released && _isActive();
  void dispose() {
    if (_released) return;
    _released = true;
    _release();
  }
}

final class GamePossessionSeat {
  final String id;
  final GameEntityHandle target;
  final bool Function(GameEntityHandle actor) canReach, canExit;
  final GamePossessionControl Function(GameEntityHandle actor) acquireControl;
  GamePossessionSeat({
    required String id,
    required this.target,
    required this.canReach,
    required this.canExit,
    required this.acquireControl,
  }) : id = _id(id);
}

/// Seat policy must use current native reach and exit clearance when applicable.
final class GamePossession {
  final GameSession session;
  final int maxSeats;
  final Map<String, GamePossessionSeat> _seats = {};
  final Map<
    GameEntityHandle,
    ({String seat, GamePossessionControl control, int epoch})
  >
  _actors = {};
  late final GameEventSubscription _state;
  bool _closed = false, _transferring = false;
  GamePossession(this.session, {this.maxSeats = 128}) {
    if (maxSeats < 1 || maxSeats > 1024 || session.isClosed) {
      throw ArgumentError('Invalid possession host.');
    }
    _state = session.listenState(_prune);
  }
  GamePossessionSeatRegistration registerSeat(GamePossessionSeat seat) {
    _prune();
    if (_closed ||
        !session.entities.isAlive(seat.target) ||
        _seats.containsKey(seat.id) ||
        _seats.length >= maxSeats) {
      throw StateError('Possession seat unavailable.');
    }
    _seats[seat.id] = seat;
    return GamePossessionSeatRegistration._(this, seat);
  }

  String? seatOf(GameEntityHandle actor) {
    _prune();
    return _actors[actor]?.seat;
  }

  GameEntityHandle? occupant(String seat) {
    _prune();
    for (final entry in _actors.entries) {
      if (entry.value.seat == seat) return entry.key;
    }
    return null;
  }

  bool transfer(GameEntityHandle actor, String? seatId) {
    if (_transferring) throw StateError('Possession transfer is reentrant.');
    _prune();
    if (_closed ||
        session.paused ||
        session.fault != null ||
        !session.entities.isAlive(actor)) {
      return false;
    }
    final old = _actors[actor];
    if (old?.seat == seatId) return true;
    final next = seatId == null ? null : _seats[seatId];
    if (seatId != null && (next == null || occupant(seatId) != null)) {
      return false;
    }
    final epoch = session.epoch;
    final oldSeat = old == null ? null : _seats[old.seat];
    GamePossessionControl? proposed;
    _transferring = true;
    bool valid() =>
        !_closed &&
        !session.paused &&
        session.fault == null &&
        session.epoch == epoch &&
        session.entities.isAlive(actor) &&
        identical(_actors[actor], old) &&
        (old == null ||
            identical(_seats[old.seat], oldSeat) &&
                oldSeat != null &&
                session.entities.isAlive(oldSeat.target)) &&
        (next == null ||
            identical(_seats[next.id], next) &&
                session.entities.isAlive(next.target) &&
                !_actors.entries.any(
                  (e) => e.key != actor && e.value.seat == next.id,
                ));
    try {
      if (oldSeat != null && !oldSeat.canExit(actor) || !valid()) return false;
      if (next != null && !next.canReach(actor) || !valid()) return false;
      proposed = next?.acquireControl(actor);
      if (!valid() || proposed != null && !proposed.isActive || !valid()) {
        return false;
      }
      _actors.remove(actor);
      if (next != null) {
        _actors[actor] = (seat: next.id, control: proposed!, epoch: epoch);
      }
      proposed = null;
      old?.control.dispose();
      return true;
    } finally {
      try {
        proposed?.dispose();
      } finally {
        _transferring = false;
        _prune();
      }
    }
  }

  void _remove(GamePossessionSeat seat) {
    if (!identical(_seats[seat.id], seat)) return;
    _seats.remove(seat.id);
    for (final actor in _actors.keys.toList()) {
      if (_actors[actor]?.seat == seat.id) _releaseActor(actor);
    }
  }

  void _releaseActor(GameEntityHandle actor) {
    _actors.remove(actor)?.control.dispose();
  }

  void _prune() {
    for (final actor in _actors.keys.toList()) {
      final held = _actors[actor];
      if (held == null) continue;
      final seat = _seats[held.seat];
      if (_closed ||
          session.paused ||
          session.isClosed ||
          session.fault != null ||
          held.epoch != session.epoch ||
          !session.entities.isAlive(actor) ||
          seat == null ||
          !session.entities.isAlive(seat.target) ||
          !held.control.isActive) {
        _releaseActor(actor);
      }
    }
    _seats.removeWhere((_, seat) => !session.entities.isAlive(seat.target));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _state.cancel();
    Object? error;
    StackTrace? stack;
    for (final actor in _actors.keys.toList()) {
      try {
        _releaseActor(actor);
      } catch (e, s) {
        error ??= e;
        stack ??= s;
      }
    }
    _seats.clear();
    if (error != null) Error.throwWithStackTrace(error, stack!);
  }
}

final class GamePossessionSeatRegistration {
  final GamePossession _owner;
  final GamePossessionSeat _seat;
  bool _disposed = false;
  GamePossessionSeatRegistration._(this._owner, this._seat);
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _owner._remove(_seat);
  }
}
