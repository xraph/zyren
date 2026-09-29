part of 'scene.dart';

mixin _Revisioned {
  int _revision = 0, _batchDepth = 0;
  bool _notificationPending = false;
  final _changes = StreamController<int>.broadcast(sync: true);
  int get revision => _revision;

  /// Coalesces synchronous edits and publishes the latest revision.
  Stream<int> get changes => _changes.stream;
  void _changed() {
    _revision++;
    _notify();
  }

  void _notify() {
    if (_batchDepth > 0 || _notificationPending || !_changes.hasListener) {
      return;
    }
    _notificationPending = true;
    scheduleMicrotask(() {
      _notificationPending = false;
      if (_batchDepth == 0) _changes.add(_revision);
    });
  }

  /// Edits remain applied if the callback throws. The outer batch still notifies.
  void batch(void Function() edits) {
    final before = _revision;
    _batchDepth++;
    try {
      edits();
    } finally {
      _batchDepth--;
      if (_revision != before) _notify();
    }
  }
}
