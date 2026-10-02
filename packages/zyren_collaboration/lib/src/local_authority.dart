import 'dart:async';
import 'model.dart';
import 'protocol.dart';

/// Host policy runs inside the authority queue and must not reenter it.
typedef SceneReadPermission =
    FutureOr<bool> Function(String principal, SceneSnapshot snapshot);
typedef SceneWritePermission =
    FutureOr<bool> Function(
      String principal,
      SceneOperation operation,
      SceneSnapshot snapshot,
    );

/// An in-process authority with serialized checks and bounded retry receipts.
/// It has no durable storage. Use a fresh epoch after losing its history.
final class LocalSceneAuthority {
  SceneSnapshot _snapshot;
  final SceneReadPermission canRead;
  final SceneWritePermission canWrite;
  final int maxReceipts;
  final Duration permissionTimeout;
  final _receipts = <(String, String), (String, int)>{};
  final _history = <SceneOperationRecord>[];
  Future<void> _tail = Future<void>.value();

  LocalSceneAuthority({
    required SceneSnapshot initial,
    required this.canRead,
    required this.canWrite,
    this.maxReceipts = 4096,
    this.permissionTimeout = const Duration(seconds: 5),
  }) : _snapshot = initial {
    if (maxReceipts < 1 || maxReceipts > 100000) {
      throw ArgumentError('Receipt capacity must be between 1 and 100000.');
    }
    if (permissionTimeout <= Duration.zero ||
        permissionTimeout > const Duration(minutes: 1)) {
      throw ArgumentError(
        'Permission timeout must be positive and at most one minute.',
      );
    }
    initial.encode();
  }

  /// Call from a trusted host after authenticating the principal.
  LocalSceneConnection connect(String principal) {
    checkText(principal, 'principal');
    return LocalSceneConnection._(this, principal);
  }

  Future<T> _serial<T>(Future<T> Function() operation) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    try {
      return await operation();
    } finally {
      done.complete();
    }
  }

  Future<bool> _canRead(String principal) => Future<bool>.sync(
    () => canRead(principal, _snapshot),
  ).timeout(permissionTimeout);
  Future<bool> _canWrite(String principal, SceneOperation operation) =>
      Future<bool>.sync(
        () => canWrite(principal, operation, _snapshot),
      ).timeout(permissionTimeout);

  Future<SceneSnapshot> _read(String principal) => _serial(() async {
    if (!await _canRead(principal)) throw const SceneAccessDenied();
    return _snapshot;
  });

  Future<SceneOperationResult> _submit(
    String principal,
    SceneOperation operation, {
    void Function()? checkBeforeCommit,
  }) => _serial(() async {
    // A successful submission includes the full snapshot, so it needs read access.
    if (!await _canRead(principal) || !await _canWrite(principal, operation)) {
      throw const SceneAccessDenied();
    }
    if (operation.sceneId != _snapshot.sceneId ||
        operation.epoch != _snapshot.epoch) {
      throw const SceneSessionMismatch();
    }
    checkBeforeCommit?.call();
    final signature = operation.encode();
    final key = (principal, operation.operationId);
    final receipt = _receipts[key];
    if (receipt != null) {
      if (receipt.$1 != signature) {
        throw StateError('An operation ID cannot identify different edits.');
      }
      return SceneOperationAccepted(
        operation: operation,
        snapshot: _snapshot,
        committedRevision: receipt.$2,
        duplicate: true,
      );
    }
    final current = _snapshot.objects[operation.objectId];
    if (current == null) throw StateError('Unknown source object.');
    if (current.revisionFor(operation.field) != operation.expectedRevision) {
      return SceneOperationConflict(operation: operation, snapshot: _snapshot);
    }
    if (_receipts.length >= maxReceipts) {
      throw const SceneReceiptCapacityExceeded();
    }
    final revision = _snapshot.revision + 1;
    final edited = SceneObjectState(
      id: current.id,
      transform: operation.transform ?? current.transform,
      visible: operation.visible ?? current.visible,
      transformRevision: operation.field == SceneField.transform
          ? revision
          : current.transformRevision,
      visibilityRevision: operation.field == SceneField.visibility
          ? revision
          : current.visibilityRevision,
    );
    final next = SceneSnapshot(
      sceneId: _snapshot.sceneId,
      epoch: _snapshot.epoch,
      revision: revision,
      objects: _snapshot.objects.values.map(
        (object) => object.id == current.id ? edited : object,
      ),
    );
    next.encode();
    // No await separates the state update and receipt insertion.
    _snapshot = next;
    _receipts[key] = (signature, revision);
    _history.add(SceneOperationRecord(operation, revision));
    return SceneOperationAccepted(
      operation: operation,
      snapshot: next,
      committedRevision: revision,
    );
  });
}

final class LocalSceneConnection
    implements
        SceneOperationTransport,
        SceneCollaborationQueries,
        GuardedSceneOperationTransport {
  final LocalSceneAuthority authority;
  final String principal;
  LocalSceneConnection._(this.authority, this.principal);
  @override
  Future<SceneSnapshot> read() => authority._read(principal);
  @override
  Future<SceneOperationResult> submit(SceneOperation operation) =>
      authority._submit(principal, operation);

  @override
  Future<SceneOperationResult> submitGuarded(
    SceneOperation operation, {
    required void Function() checkBeforeCommit,
  }) => authority._submit(
    principal,
    operation,
    checkBeforeCommit: checkBeforeCommit,
  );

  @override
  Future<SceneHistoryPage> history({
    required int expectedRevision,
    int afterRevision = 0,
    int limit = 50,
  }) => authority._serial(() async {
    if (!await authority._canRead(principal)) {
      throw const SceneAccessDenied();
    }
    checkRevision(afterRevision);
    if (limit < 1 || limit > 100) {
      throw ArgumentError('History limit is 1 to 100.');
    }
    if (authority._snapshot.revision != expectedRevision) {
      throw const SceneRevisionMismatch();
    }
    final entries = authority._history
        .where((entry) => entry.revision > afterRevision)
        .take(limit + 1)
        .toList();
    return SceneHistoryPage(
      sceneRevision: authority._snapshot.revision,
      records: entries.take(limit),
      nextAfterRevision: entries.length > limit
          ? entries[limit - 1].revision
          : null,
    );
  });

  @override
  Future<bool> allows(SceneOperation operation) => authority._serial(() async {
    final snapshot = authority._snapshot;
    if (!await authority._canRead(principal)) {
      throw const SceneAccessDenied();
    }
    if (snapshot.sceneId != operation.sceneId ||
        snapshot.epoch != operation.epoch) {
      throw const SceneSessionMismatch();
    }
    if (!snapshot.objects.containsKey(operation.objectId)) {
      throw StateError('Unknown source object.');
    }
    return authority._canWrite(principal, operation);
  });
}
