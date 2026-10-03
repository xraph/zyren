part of '../../zyren_game.dart';

final class ObjectiveTracker {
  final Map<String, int> targets;
  final Map<String, int> _progress = {};
  final Set<String> _receipts = {};
  final int receiptCapacity;
  ObjectiveTracker(Map<String, int> targets, {this.receiptCapacity = 4096})
    : targets = Map.unmodifiable(targets) {
    _validateItems(targets);
    if (targets.isEmpty) {
      throw const FormatException('Objectives must not be empty.');
    }
    _limit(receiptCapacity, 65536, 'objective receipts');
  }
  Map<String, int> get progress => Map.unmodifiable(_progress);
  bool get completed =>
      targets.entries.every((e) => (_progress[e.key] ?? 0) >= e.value);
  bool credit(String id, {required String receipt, int count = 1}) {
    _id(receipt);
    final target = targets[id];
    final previous = _progress[id] ?? 0;
    if (target == null ||
        count < 1 ||
        previous >= target ||
        _receipts.contains(receipt) ||
        _receipts.length >= receiptCapacity) {
      return false;
    }
    _receipts.add(receipt);
    _progress[id] = previous + count > target ? target : previous + count;
    return true;
  }

  Map<String, Object?> toJson() => {
    'targets': targets,
    'progress': progress,
    'receipts': _receipts.toList(),
    'receiptCapacity': receiptCapacity,
  };
  factory ObjectiveTracker.fromJson(Map<String, Object?> data) {
    final result = ObjectiveTracker(
      _itemMap(data['targets']),
      receiptCapacity: _integer(data['receiptCapacity'] ?? 4096),
    );
    final progress = _itemMap(data['progress'] ?? <String, Object?>{});
    for (final entry in progress.entries) {
      if (!result.targets.containsKey(entry.key) ||
          entry.value < 0 ||
          entry.value > result.targets[entry.key]!) {
        throw const FormatException('Invalid objective progress.');
      }
    }
    final receipts = _list(
      data['receipts'] ?? <Object?>[],
    ).map((r) => _id(_string(r))).toList();
    if (receipts.length > result.receiptCapacity ||
        receipts.toSet().length != receipts.length) {
      throw const FormatException('Invalid objective receipts.');
    }
    result._progress.addAll(progress);
    result._receipts.addAll(receipts);
    return result;
  }
}
