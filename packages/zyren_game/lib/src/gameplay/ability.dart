part of '../../zyren_game.dart';

final class AbilityActivated {
  final GameEntityHandle actor;
  final String abilityId;
  final int tick, sequence;
  const AbilityActivated(this.actor, this.abilityId, this.tick, this.sequence);
}

final class AbilityFinished {
  final AbilityActivated activation;
  final bool cancelled;
  const AbilityFinished(this.activation, {required this.cancelled});
}

/// Costs commit at activation. Interruption retains spent costs and cooldown.
final class Ability {
  final String id;
  final int cooldownTicks, durationTicks;
  final Map<String, int> costs;
  int _nextAllowedTick = 0, _lastTick = -1, _sequence = 0;
  AbilityActivated? _active;
  Ability({
    required String id,
    required this.cooldownTicks,
    this.durationTicks = 0,
    Map<String, int> costs = const {},
  }) : id = _id(id),
       costs = Map.unmodifiable(costs) {
    _validateItems(costs);
    if (cooldownTicks < 0 ||
        cooldownTicks > 100000000 ||
        durationTicks < 0 ||
        durationTicks > 100000000) {
      throw const FormatException('Invalid ability tick duration.');
    }
  }
  int get nextAllowedTick => _nextAllowedTick;
  AbilityActivated? get active => _active;
  void _checkTick(int tick) {
    if (tick < 0 || tick < _lastTick) {
      throw StateError('Ability ticks must not go backwards.');
    }
    _lastTick = tick;
  }

  AbilityActivated? tryActivate({
    required GameEntityHandle actor,
    required Inventory inventory,
    required int tick,
  }) {
    _checkTick(tick);
    if (_active != null ||
        tick < _nextAllowedTick ||
        !inventory.contains(costs)) {
      return null;
    }
    inventory.consume(costs);
    _nextAllowedTick = tick + cooldownTicks;
    return _active = AbilityActivated(actor, id, tick, _sequence++);
  }

  AbilityFinished? advance(int tick) {
    _checkTick(tick);
    final active = _active;
    if (active == null || tick < active.tick + durationTicks) return null;
    _active = null;
    return AbilityFinished(active, cancelled: false);
  }

  bool cancel(GameEntityHandle actor) {
    if (_active?.actor != actor) return false;
    _active = null;
    return true;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'cooldownTicks': cooldownTicks,
    'durationTicks': durationTicks,
    'costs': costs,
    'nextAllowedTick': _nextAllowedTick,
    'lastTick': _lastTick,
    'sequence': _sequence,
  };

  /// Restoring cancels in-flight execution while preserving committed cost/cooldown.
  factory Ability.fromJson(Map<String, Object?> data) {
    final ability = Ability(
      id: _string(data['id']),
      cooldownTicks: _integer(data['cooldownTicks']),
      durationTicks: _integer(data['durationTicks'] ?? 0),
      costs: _itemMap(data['costs'] ?? <String, Object?>{}),
    );
    final next = _integer(data['nextAllowedTick'] ?? 0);
    final last = _integer(data['lastTick'] ?? -1);
    final sequence = _integer(data['sequence'] ?? 0);
    if (next < 0 || last < -1 || sequence < 0) {
      throw const FormatException('Invalid ability state.');
    }
    ability._nextAllowedTick = next;
    ability._lastTick = last;
    ability._sequence = sequence;
    return ability;
  }
}

/// One actor's named ability states, stored together as a single component.
final class GameAbilityCollection {
  final Map<String, Ability> abilities;
  GameAbilityCollection(Map<String, Ability> abilities)
    : abilities = Map.unmodifiable(abilities) {
    if (abilities.length > 64 ||
        abilities.entries.any((e) => e.key != e.value.id)) {
      throw const FormatException('Invalid ability collection.');
    }
  }
  Map<String, Object?> toJson() => {
    'abilities': abilities.values.map((a) => a.toJson()).toList(),
  };
  factory GameAbilityCollection.fromJson(Map<String, Object?> data) {
    final values = _list(data['abilities']);
    if (values.length > 64) throw const FormatException('Too many abilities.');
    final result = <String, Ability>{};
    for (final value in values) {
      final ability = Ability.fromJson(_map(value));
      if (result.containsKey(ability.id)) {
        throw const FormatException('Duplicate ability.');
      }
      result[ability.id] = ability;
    }
    return GameAbilityCollection(result);
  }
}
