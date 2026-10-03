import 'dart:convert';
import 'client.dart';
import 'durable_authority.dart';
import 'model.dart';
import 'protocol.dart';

final class OfflineSceneState {
  final SceneSnapshot snapshot;
  final List<SceneOperation> pending;
  final SceneOperationConflict? conflict;
  final String? lastError;
  OfflineSceneState({
    required this.snapshot,
    Iterable<SceneOperation> pending = const [],
    this.conflict,
    this.lastError,
  }) : pending = List.unmodifiable(pending);
  String encode() => boundedEncode({
    'schemaVersion': 1,
    'snapshot': snapshot.encode(),
    'pending': pending.map((op) => op.encode()).toList(),
    if (conflict != null) 'conflict': conflict!.snapshot.encode(),
    if (lastError != null) 'lastError': lastError,
  }, 16 * 1024 * 1024);
  factory OfflineSceneState.decode(String source) {
    final j = boundedDecode(source, 16 * 1024 * 1024);
    if (j['schemaVersion'] != 1 ||
        j['pending'] is! List ||
        (j['pending'] as List).length > 256) {
      throw const FormatException('Invalid offline queue.');
    }
    final snapshot = SceneSnapshot.decode(textValue(j['snapshot']));
    final pending = (j['pending'] as List)
        .map((op) => SceneOperation.decode(textValue(op)))
        .toList();
    final fields = <(SceneObjectId, SceneField)>{};
    final ids = <String>{};
    for (final op in pending) {
      if (op.sceneId != snapshot.sceneId ||
          op.epoch != snapshot.epoch ||
          !snapshot.objects.containsKey(op.objectId) ||
          !fields.add((op.objectId, op.field)) ||
          !ids.add(op.operationId)) {
        throw const FormatException(
          'Invalid offline identity or duplicate field.',
        );
      }
    }
    if (j['conflict'] != null && pending.isEmpty) {
      throw const FormatException('Conflict needs a pending edit.');
    }
    final conflict = j['conflict'] == null
        ? null
        : SceneOperationConflict(
            operation: pending.first,
            snapshot: SceneSnapshot.decode(textValue(j['conflict'])),
          );
    if (conflict != null &&
        (conflict.snapshot.sceneId != snapshot.sceneId ||
            conflict.snapshot.epoch != snapshot.epoch ||
            !conflict.snapshot.objects.containsKey(
              conflict.operation.objectId,
            ) ||
            conflict.actualRevision == conflict.operation.expectedRevision)) {
      throw const FormatException('Invalid saved conflict.');
    }
    return OfflineSceneState(
      snapshot: snapshot,
      pending: pending,
      conflict: conflict,
      lastError: j['lastError'] == null ? null : textValue(j['lastError']),
    );
  }
}

/// Durable exact-operation outbox. One pending decision per object field keeps
/// revision dependencies explicit. Reconcile before editing that field again.
/// Use one queue per authenticated principal and asset epoch; never share it
/// between accounts. The store owns serialization and crash-safe replacement.
final class OfflineSceneQueue {
  final SceneDocumentStore store;
  final SceneOperationTransport transport;
  final String sceneId, epoch, ownerId;
  OfflineSceneQueue({
    required this.store,
    required this.transport,
    required this.sceneId,
    required this.epoch,
    required this.ownerId,
  }) {
    checkText(sceneId, 'sceneId');
    checkText(epoch, 'epoch');
    checkText(ownerId, 'ownerId');
  }
  String _encode(OfflineSceneState state) => jsonEncode({
    ...jsonDecode(state.encode()) as Map<String, dynamic>,
    'ownerId': ownerId,
  });
  void _identity(SceneSnapshot snapshot) {
    if (snapshot.sceneId != sceneId || snapshot.epoch != epoch) {
      throw const SceneSessionMismatch();
    }
  }

  Future<void> initialize(SceneSnapshot acknowledged) =>
      store.transact((current) async {
        _identity(acknowledged);
        if (current != null) {
          _state(current);
          return (null, null);
        }
        return (null, _encode(OfflineSceneState(snapshot: acknowledged)));
      });
  OfflineSceneState _state(String? current) {
    if (current == null) {
      throw StateError('Initialize the offline queue first.');
    }
    if (boundedDecode(current, 16 * 1024 * 1024)['ownerId'] != ownerId) {
      throw const SceneAccessDenied();
    }
    final state = OfflineSceneState.decode(current);
    _identity(state.snapshot);
    return state;
  }

  Future<OfflineSceneState> read() =>
      store.transact((current) async => (_state(current), null));
  Future<void> enqueue(SceneOperation operation) => store.transact((
    current,
  ) async {
    final state = _state(current);
    if (operation.sceneId != sceneId || operation.epoch != epoch) {
      throw const SceneSessionMismatch();
    }
    final object = state.snapshot.objects[operation.objectId];
    if (object == null ||
        object.revisionFor(operation.field) != operation.expectedRevision) {
      throw const SceneRevisionMismatch();
    }
    if (operation.undoOfRevision != null) {
      throw StateError('Prepare undo through the authority.');
    }
    if (state.pending.length >= 256 ||
        state.pending.any(
          (op) =>
              op.operationId == operation.operationId ||
              op.objectId == operation.objectId && op.field == operation.field,
        )) {
      throw StateError('Resolve the queued field before editing it again.');
    }
    return (
      null,
      _encode(
        OfflineSceneState(
          snapshot: state.snapshot,
          pending: [...state.pending, operation],
          conflict: state.conflict,
          lastError: state.lastError,
        ),
      ),
    );
  });
  Future<OfflineSceneState> reconcile({
    void Function()? checkBeforeSend,
  }) async {
    while (true) {
      final result = await store.transact((current) async {
        final state = _state(current);
        if (state.conflict != null) return ((state, false), null);
        final client = SceneCollaborationClient.restore(
          transport: transport,
          snapshot: state.snapshot,
          pending: state.pending.firstOrNull,
          nextOperationId: () =>
              throw StateError('Reconciliation cannot invent a decision.'),
        );
        try {
          checkBeforeSend?.call();
          if (state.pending.isEmpty) {
            await client.refresh();
            final next = OfflineSceneState(snapshot: client.snapshot!);
            return ((next, false), _encode(next));
          }
          // Do not read then rebase. Submit the exact saved conditional edit.
          final result = await client.flush();
          final conflict = result is SceneOperationConflict ? result : null;
          final remaining = conflict == null
              ? state.pending.skip(1)
              : state.pending;
          final next = OfflineSceneState(
            snapshot: client.snapshot!,
            pending: remaining,
            conflict: conflict,
          );
          return (
            (next, conflict == null && next.pending.isNotEmpty),
            _encode(next),
          );
        } catch (error) {
          final next = OfflineSceneState(
            snapshot: state.snapshot,
            pending: state.pending,
            lastError: switch (error) {
              SceneSessionMismatch() => 'epoch_changed',
              SceneAccessDenied() => 'denied',
              SceneReceiptCapacityExceeded() => 'capacity',
              _ => 'retry_required',
            },
          );
          // Retain uncertain writes and errors without serializing credentials.
          return ((next, false), _encode(next));
        } finally {
          await client.close();
        }
      });
      if (!result.$2) return result.$1;
    }
  }

  Future<void> acceptRemote({required SceneOperationConflict reviewed}) =>
      _resolve(null, reviewed);
  Future<void> keepLocal(
    String newOperationId, {
    required SceneOperationConflict reviewed,
  }) => _resolve(newOperationId, reviewed);
  Future<void> _resolve(
    String? newId,
    SceneOperationConflict reviewed,
  ) => store.transact((current) async {
    final state = _state(current), conflict = _state(current).conflict;
    if (conflict == null) {
      throw StateError('No confirmed conflict. Retry uncertain writes first.');
    }
    if (conflict.operation.encode() != reviewed.operation.encode() ||
        conflict.snapshot.encode() != reviewed.snapshot.encode()) {
      throw const SceneRevisionMismatch();
    }
    final pending = state.pending.skip(1).toList();
    if (newId != null) {
      if (state.pending.any((op) => op.operationId == newId)) {
        throw StateError('A new decision requires a new ID.');
      }
      pending.insert(
        0,
        conflict.operation.retryAgainst(
          newOperationId: newId,
          revision: conflict.actualRevision,
        ),
      );
    }
    return (
      null,
      _encode(OfflineSceneState(snapshot: state.snapshot, pending: pending)),
    );
  });
}
