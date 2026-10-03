part of '../../zyren_game.dart';

/// Capacity counts item units. A failed mutation leaves the entire bag unchanged.
final class Inventory {
  final int capacity;
  final Map<String, int> _items;
  Inventory({required this.capacity, Map<String, int> items = const {}})
    : _items = Map.of(items) {
    _limit(capacity, 1000000, 'inventory capacity');
    _validateItems(_items);
    if (total > capacity) {
      throw const FormatException('Inventory exceeds capacity.');
    }
  }
  int get total => _items.values.fold(0, (sum, value) => sum + value);
  Map<String, int> get items => Map.unmodifiable(_items);
  int count(String item) => _items[item] ?? 0;
  bool contains(Map<String, int> costs) {
    _validateItems(costs);
    return costs.entries.every((e) => count(e.key) >= e.value);
  }

  bool add(String item, int count) {
    _id(item);
    if (count < 1 ||
        count > capacity - total ||
        (!_items.containsKey(item) && _items.length >= 256)) {
      return false;
    }
    _items[item] = this.count(item) + count;
    return true;
  }

  bool consume(Map<String, int> costs) {
    if (!contains(costs)) return false;
    for (final entry in costs.entries) {
      final next = count(entry.key) - entry.value;
      if (next == 0) {
        _items.remove(entry.key);
      } else {
        _items[entry.key] = next;
      }
    }
    return true;
  }

  bool transfer({
    required String item,
    required int count,
    required Inventory to,
  }) {
    _id(item);
    if (identical(this, to) ||
        count < 1 ||
        this.count(item) < count ||
        to.total + count > to.capacity ||
        (!to._items.containsKey(item) && to._items.length >= 256)) {
      return false;
    }
    to._items[item] = to.count(item) + count;
    final remaining = this.count(item) - count;
    if (remaining == 0) {
      _items.remove(item);
    } else {
      _items[item] = remaining;
    }
    return true;
  }

  Map<String, Object?> toJson() => {'capacity': capacity, 'items': items};
  factory Inventory.fromJson(Map<String, Object?> data) => Inventory(
    capacity: _integer(data['capacity']),
    items: _itemMap(data['items']),
  );
}

void _validateItems(Map<String, int> items) {
  if (items.length > 256) {
    throw const FormatException('Item type limit exceeded.');
  }
  for (final entry in items.entries) {
    _id(entry.key);
    if (entry.value < 1 || entry.value > 1000000) {
      throw const FormatException('Item counts must be in 1..1000000.');
    }
  }
}

Map<String, int> _itemMap(Object? value) =>
    _map(value).map((key, value) => MapEntry(key, _integer(value)));

void registerGameplayComponents(GameRegistry registry) {
  registry.registerComponent(
    _GameplayCodec<Inventory>('game.inventory', Inventory.fromJson),
  );
  registry.registerComponent(
    _GameplayCodec<Ability>('game.ability', Ability.fromJson),
  );
  registry.registerComponent(
    _GameplayCodec<GameAbilityCollection>(
      'game.abilities',
      GameAbilityCollection.fromJson,
    ),
  );
  registry.registerComponent(
    _GameplayCodec<ObjectiveTracker>(
      'game.objectives',
      ObjectiveTracker.fromJson,
    ),
  );
}

final class _GameplayCodec<T extends Object> extends GameComponentCodec<T> {
  @override
  final String type;
  final T Function(Map<String, Object?>) _decode;
  _GameplayCodec(this.type, this._decode);
  @override
  int get version => 1;
  @override
  void validate(Map<String, Object?> data) {
    _decode(data);
  }

  @override
  T factory(Map<String, Object?> data) => _decode(data);
  @override
  Iterable<GameLocalReference> localReferences(Map<String, Object?> data) =>
      const [];
  @override
  Map<String, Object?> migrate(int fromVersion, Map<String, Object?> data) =>
      throw FormatException('Unsupported $type schema $fromVersion.');
}
