part of '../../zyren_game.dart';

/// Query adapters establish reach; this rule validates identity and commits costs.
final class GameInteraction {
  final String id;
  final GameEntityHandle target;
  final Map<String, int> requiredItems;
  final bool consumeItems;
  final int receiptCapacity;
  final Set<String> _receipts = {};
  GameInteraction({
    required String id,
    required this.target,
    Map<String, int> requiredItems = const {},
    this.consumeItems = false,
    this.receiptCapacity = 4096,
  }) : id = _id(id),
       requiredItems = Map.unmodifiable(requiredItems) {
    _validateItems(requiredItems);
    _limit(receiptCapacity, 65536, 'interaction receipts');
  }
  bool tryApply({
    required GameEntityHandle actor,
    required GameEntityTable entities,
    required Inventory inventory,
    required String receipt,
    required bool inReach,
  }) {
    _id(receipt);
    if (!inReach ||
        !entities.isAlive(actor) ||
        !entities.isAlive(target) ||
        _receipts.contains(receipt) ||
        _receipts.length >= receiptCapacity ||
        !inventory.contains(requiredItems)) {
      return false;
    }
    if (consumeItems) inventory.consume(requiredItems);
    _receipts.add(receipt);
    return true;
  }
}
