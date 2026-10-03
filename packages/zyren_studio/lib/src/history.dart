part of '../zyren_studio.dart';

/// Bounded document history. Navigation does not invalidate an authored edit.
final class StudioHistory {
  final int limit;
  final int byteLimit;
  final _undo = <(StudioDocument, StudioDocument)>[];
  final _redo = <(StudioDocument, StudioDocument)>[];
  StudioHistory({this.limit = 64, this.byteLimit = 32 * 1024 * 1024}) {
    if (limit < 1 || byteLimit < 1) {
      throw ArgumentError('Invalid history budget.');
    }
  }
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  Iterable<StudioDocument> get documents sync* {
    for (final pair in [..._undo, ..._redo]) {
      yield pair.$1;
      yield pair.$2;
    }
  }

  String _authored(StudioDocument document) {
    final json = jsonDecode(document.encode()) as Map<String, dynamic>;
    json.remove('camera');
    return jsonEncode(json);
  }

  void record(StudioDocument before, StudioDocument after) {
    if (_authored(before) == _authored(after)) return;
    _undo.add((before, after));
    _redo.clear();
    while (_undo.length > limit ||
        _undo.fold(
              0,
              (int n, pair) =>
                  n +
                  utf8.encode(pair.$1.encode()).length +
                  utf8.encode(pair.$2.encode()).length,
            ) >
            byteLimit) {
      _undo.removeAt(0);
    }
  }

  bool undo(StudioDocument current, void Function(StudioDocument) apply) =>
      _step(_undo, _redo, current, apply, false);
  bool redo(StudioDocument current, void Function(StudioDocument) apply) =>
      _step(_redo, _undo, current, apply, true);
  bool _step(
    List<(StudioDocument, StudioDocument)> from,
    List<(StudioDocument, StudioDocument)> to,
    StudioDocument current,
    void Function(StudioDocument) apply,
    bool forward,
  ) {
    if (from.isEmpty) return false;
    final pair = from.last;
    if (_authored(current) != _authored(forward ? pair.$1 : pair.$2)) {
      throw StateError(
        'History changed outside this editor. Refresh before undo.',
      );
    }
    apply((forward ? pair.$2 : pair.$1).copyWith(camera: current.camera));
    from.removeLast();
    to.add(pair);
    return true;
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }
}
