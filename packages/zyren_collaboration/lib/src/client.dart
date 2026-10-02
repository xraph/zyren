import 'dart:async';
import 'model.dart';
import 'protocol.dart';

/// One pending edit at a time. Transport failures retain the exact operation.
/// You own transport deadlines, cancellation, credentials and its disposal.
final class SceneCollaborationClient {
  final SceneOperationTransport transport;
  final String sceneId, epoch;
  final String Function() nextOperationId;
  final _changes = StreamController<SceneSnapshot>.broadcast(sync: true);
  SceneSnapshot? _snapshot;
  SceneOperation? _pending;
  SceneOperationConflict? _conflict;
  bool _busy = false, _closed = false;

  SceneCollaborationClient({
    required this.transport,
    required this.sceneId,
    required this.epoch,
    required this.nextOperationId,
  }) {
    checkText(sceneId, 'sceneId');
    checkText(epoch, 'epoch');
  }
  SceneSnapshot? get snapshot => _snapshot;
  SceneOperation? get pending => _pending;
  SceneOperationConflict? get conflict => _conflict;
  bool get isBusy => _busy;
  bool get isClosed => _closed;
  Stream<SceneSnapshot> get changes => _changes.stream;

  Future<SceneSnapshot> refresh() => _request(() async {
    final next = await transport.read();
    _checkOpen();
    _adopt(next);
    return _snapshot!;
  });

  SceneOperation setTransform(SceneObjectId id, SceneTransform transform) =>
      _prepare(id, SceneField.transform, transform: transform);
  SceneOperation setVisible(SceneObjectId id, bool visible) =>
      _prepare(id, SceneField.visibility, visible: visible);

  SceneOperation _prepare(
    SceneObjectId id,
    SceneField field, {
    SceneTransform? transform,
    bool? visible,
  }) {
    _checkIdle();
    if (_pending != null) throw StateError('Resolve the pending edit first.');
    final state = _snapshot?.objects[id];
    if (state == null) {
      throw StateError('Read the source object before editing.');
    }
    final operation = SceneOperation(
      sceneId: sceneId,
      epoch: epoch,
      operationId: nextOperationId(),
      objectId: id,
      expectedRevision: state.revisionFor(field),
      field: field,
      transform: transform,
      visible: visible,
    );
    operation.encode();
    return _pending = operation;
  }

  Future<SceneOperationResult> flush() => _request(() async {
    final operation = _pending;
    if (operation == null) throw StateError('No pending scene edit.');
    final result = await transport.submit(operation);
    _checkOpen();
    _validate(result, operation);
    _adopt(result.snapshot);
    if (result is SceneOperationAccepted) {
      _pending = null;
      _conflict = null;
    } else {
      _conflict = result as SceneOperationConflict;
    }
    return result;
  });

  /// Discards an edit only after an authority confirmed its conflict.
  /// A transport error is ambiguous: retry it before making this decision.
  void acceptRemote() {
    _checkIdle();
    if (_conflict == null) {
      throw StateError('No confirmed conflict to resolve.');
    }
    _pending = null;
    _conflict = null;
  }

  /// Keeps the proposed value against the exact revision the host reviewed.
  /// An intervening edit produces another conflict when you flush.
  SceneOperation keepLocal() {
    _checkIdle();
    final conflict = _conflict;
    if (conflict == null) throw StateError('No confirmed conflict to resolve.');
    final operation = conflict.operation.retryAgainst(
      newOperationId: nextOperationId(),
      revision: conflict.actualRevision,
    );
    if (operation.operationId == conflict.operation.operationId) {
      throw StateError('A conflict decision needs a new operation ID.');
    }
    operation.encode();
    _pending = operation;
    _conflict = null;
    return operation;
  }

  void _validate(SceneOperationResult result, SceneOperation operation) {
    if (result.operation.encode() != operation.encode()) {
      throw StateError(
        'Transport returned a receipt for a different operation.',
      );
    }
    _checkIdentity(result.snapshot);
    final current = result.snapshot.objects[operation.objectId];
    if (current == null) {
      throw StateError('Receipt is missing the source object.');
    }
    final fieldRevision = current.revisionFor(operation.field);
    if (result is SceneOperationConflict) {
      if (fieldRevision == operation.expectedRevision) {
        throw StateError(
          'Transport returned a conflict without a revision change.',
        );
      }
    } else if (result is SceneOperationAccepted) {
      final revision = result.committedRevision;
      if (revision <= operation.expectedRevision ||
          revision > result.snapshot.revision ||
          fieldRevision < revision ||
          fieldRevision == revision &&
              (operation.field == SceneField.transform
                  ? current.transform != operation.transform
                  : current.visible != operation.visible)) {
        throw StateError('Transport returned an inconsistent commit receipt.');
      }
    }
  }

  void _checkIdentity(SceneSnapshot value) {
    if (value.sceneId != sceneId || value.epoch != epoch) {
      throw const SceneSessionMismatch();
    }
  }

  void _adopt(SceneSnapshot value) {
    _checkIdentity(value);
    final prior = _snapshot;
    if (prior != null) {
      if (value.revision < prior.revision) return;
      if (value.revision == prior.revision) {
        if (value.encode() != prior.encode()) {
          throw StateError('The same scene revision returned different state.');
        }
        return;
      }
      if (value.objects.length != prior.objects.length ||
          !value.objects.keys.every(prior.objects.containsKey)) {
        throw StateError('The object set changed without a new scene epoch.');
      }
    }
    _snapshot = value;
    _changes.add(value);
  }

  Future<T> _request<T>(Future<T> Function() operation) async {
    _checkIdle();
    _busy = true;
    try {
      return await operation();
    } finally {
      _busy = false;
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('Collaboration client is closed.');
  }

  void _checkIdle() {
    _checkOpen();
    if (_busy) throw StateError('A collaboration request is already running.');
  }

  /// Closing prevents late replies from changing state; transport stays host-owned.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _changes.close();
  }
}
