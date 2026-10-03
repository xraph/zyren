import 'dart:async';
import 'dart:convert';
import 'local_authority.dart';
import 'model.dart';
import 'protocol.dart';

/// A transaction returns its result and optional replacement document.
/// Stores serialize callbacks, including across processes where supported.
abstract interface class SceneDocumentStore {
  Future<T> transact<T>(Future<(T, String?)> Function(String? current) action);
}

final class MemorySceneDocumentStore implements SceneDocumentStore {
  String? _value;
  Future<void> _tail = Future.value();
  @override
  Future<T> transact<T>(Future<(T, String?)> Function(String?) action) async {
    final previous = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    await previous;
    try {
      final (result, replacement) = await action(_value);
      if (replacement != null) _value = replacement;
      return result;
    } finally {
      gate.complete();
    }
  }
}

/// Validates and replays the bounded ledger inside each store transaction.
/// Choose file storage for restart recovery; memory storage is process-local.
final class DurableSceneAuthority {
  final SceneDocumentStore store;
  final SceneReadPermission canRead;
  final SceneWritePermission canWrite;
  final int maxReceipts;
  final Duration permissionTimeout;
  DurableSceneAuthority({
    required this.store,
    required this.canRead,
    required this.canWrite,
    this.maxReceipts = 4096,
    this.permissionTimeout = const Duration(seconds: 5),
  });

  Future<void> initialize(SceneSnapshot initial) => store.transact((
    current,
  ) async {
    final authority = current == null
        ? LocalSceneAuthority(
            initial: initial,
            canRead: canRead,
            canWrite: canWrite,
            maxReceipts: maxReceipts,
            permissionTimeout: permissionTimeout,
          )
        : await _restore(current);
    final saved = SceneSnapshot.decode(
      jsonEncode(
        boundedDecode(authority.exportArchive(), 32 * 1024 * 1024)['initial'],
      ),
    );
    if (saved.sceneId != initial.sceneId || saved.epoch != initial.epoch) {
      throw const SceneSessionMismatch();
    }
    return (null, current == null ? authority.exportArchive() : null);
  });

  Future<LocalSceneAuthority> _restore(String current) =>
      LocalSceneAuthority.restore(
        archive: current,
        canRead: canRead,
        canWrite: canWrite,
        maxReceipts: maxReceipts,
        permissionTimeout: permissionTimeout,
      );

  DurableSceneConnection connect(String principal) {
    checkText(principal, 'principal');
    return DurableSceneConnection._(this, principal);
  }

  Future<T> _run<T>(
    String principal,
    Future<T> Function(LocalSceneConnection) action, {
    bool write = false,
    void Function()? guard,
  }) => store.transact((current) async {
    if (current == null) {
      throw StateError('Initialize the scene authority first.');
    }
    final authority = await _restore(current);
    final result = await action(authority.connect(principal));
    guard?.call();
    return (result, write ? authority.exportArchive() : null);
  });
}

final class DurableSceneConnection
    implements
        SceneOperationTransport,
        SceneCollaborationQueries,
        SceneUndoTransport,
        GuardedSceneOperationTransport {
  final DurableSceneAuthority authority;
  final String principal;
  DurableSceneConnection._(this.authority, this.principal);
  @override
  Future<SceneSnapshot> read() => authority._run(principal, (c) => c.read());
  @override
  Future<SceneOperationResult> submit(SceneOperation operation) =>
      authority._run(principal, (c) => c.submit(operation), write: true);
  @override
  Future<SceneOperationResult> submitGuarded(
    SceneOperation operation, {
    required void Function() checkBeforeCommit,
  }) => authority._run(
    principal,
    (c) => c.submitGuarded(operation, checkBeforeCommit: checkBeforeCommit),
    write: true,
    guard: checkBeforeCommit,
  );
  @override
  Future<SceneOperationResult> undo({
    required int revision,
    required String operationId,
  }) => authority._run(
    principal,
    (c) => c.undo(revision: revision, operationId: operationId),
    write: true,
  );
  @override
  Future<bool> allows(SceneOperation operation) =>
      authority._run(principal, (c) => c.allows(operation));
  @override
  Future<SceneHistoryPage> history({
    required int expectedRevision,
    int afterRevision = 0,
    int limit = 50,
  }) => authority._run(
    principal,
    (c) => c.history(
      expectedRevision: expectedRevision,
      afterRevision: afterRevision,
      limit: limit,
    ),
  );
}
