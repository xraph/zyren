/// Bounded state pairs. Owners move entries only after a successful scene swap.
final class ScientificHistory<T> {
  final int limit, byteLimit;
  final int Function(T) payloadBytes;
  final _undo = <({T before, T after, String label, int bytes})>[];
  final _redo = <({T before, T after, String label, int bytes})>[];
  int _bytes = 0;

  ScientificHistory({
    required this.limit,
    required this.byteLimit,
    required this.payloadBytes,
  }) {
    if (limit < 0 ||
        limit > 256 ||
        byteLimit < 0 ||
        byteLimit > 64 * 1024 * 1024) {
      throw ArgumentError('History permits 0..256 entries and up to 64 MiB.');
    }
  }

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  T target(bool redo) => redo ? _redo.last.after : _undo.last.before;

  void record(T before, T after, String label) {
    for (final entry in _redo) {
      _bytes -= entry.bytes;
    }
    _redo.clear();
    final bytes = payloadBytes(before) + payloadBytes(after);
    _undo.add((before: before, after: after, label: label, bytes: bytes));
    _bytes += bytes;
    while (_undo.length > limit || _bytes > byteLimit) {
      _bytes -= _undo.removeAt(0).bytes;
    }
  }

  void move(bool redo) {
    final from = redo ? _redo : _undo;
    (redo ? _undo : _redo).add(from.removeLast());
  }

  Map<String, Object?> describe() => {
    'canUndo': canUndo,
    'canRedo': canRedo,
    'undoCount': _undo.length,
    'redoCount': _redo.length,
    'undoLabel': canUndo ? _undo.last.label : null,
    'redoLabel': canRedo ? _redo.last.label : null,
    'undoLabels': [for (final entry in _undo.reversed) entry.label],
    'redoLabels': [for (final entry in _redo.reversed) entry.label],
    'retainedPayloadBytes': _bytes,
    'entryLimit': limit,
    'byteLimit': byteLimit,
    'storage': 'session-immutable-source-and-settings; no GPU resources',
  };

  void clear() {
    _undo.clear();
    _redo.clear();
    _bytes = 0;
  }
}
