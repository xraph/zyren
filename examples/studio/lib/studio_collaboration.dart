import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';
import 'package:zyren_collaboration/network.dart';
import 'package:zyren_collaboration/file_store.dart';
import 'package:zyren_collaboration/agent_provider.dart';
import 'package:zyren_agents/zyren_agents.dart';

String studioEpoch(StudioDocument document) {
  final nodes = document.expandedNodes.values.toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  final assets = document.assets.toList()..sort((a, b) => a.id.compareTo(b.id));
  return sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'documentId': document.id,
            'nodes': [
              for (final node in nodes)
                node.toJson()
                  ..remove('position')
                  ..remove('rotation')
                  ..remove('scale')
                  ..remove('visible')
                  ..remove('overrides'),
            ],
            'assets': [for (final asset in assets) asset.toJson()],
          }),
        ),
      )
      .toString();
}

String _nonce() => base64UrlEncode(
  List<int>.generate(24, (_) => Random.secure().nextInt(256)),
).replaceAll('=', '');

SceneSnapshot studioSnapshot(StudioScene scene) => SceneSnapshot(
  sceneId: scene.document.id,
  epoch: studioEpoch(scene.capture()),
  objects: [
    for (final entry in scene.objects.entries)
      SceneObjectState(
        id: SceneObjectId(source: scene.document.id, key: entry.key),
        transform: SceneTransform.capture(entry.value),
        visible: entry.value.visible,
      ),
  ],
);

/// A local authenticated room uses the same durable authority as remote hosts.
final class StudioRoom {
  final DurableSceneAuthority authority;
  final ScenePresenceAuthority presence;
  final SceneCollaborationServer server;
  final String editorToken, viewerToken;
  StudioRoom._(
    this.authority,
    this.presence,
    this.server,
    this.editorToken,
    this.viewerToken,
  );
  static Future<StudioRoom> host(StudioScene scene, Directory directory) async {
    final snapshot = studioSnapshot(scene);
    final authority = DurableSceneAuthority(
      store: FileSceneDocumentStore(
        File('${directory.path}/${snapshot.sceneId}-${snapshot.epoch}.room'),
      ),
      canRead: (who, _) => {'owner', 'editor', 'viewer'}.contains(who),
      canWrite: (who, _, _) => {'owner', 'editor'}.contains(who),
    );
    await authority.initialize(snapshot);
    final presence = ScenePresenceAuthority(
      authorize: (who) => {'owner', 'editor', 'viewer'}.contains(who),
    );
    final editorToken = _nonce(), viewerToken = _nonce();
    final server = await SceneCollaborationServer.bind(
      sceneId: snapshot.sceneId,
      epoch: snapshot.epoch,
      authenticate: (request) =>
          switch (request.headers.value('authorization')) {
            final value when value == 'Bearer $editorToken' => 'editor',
            final value when value == 'Bearer $viewerToken' => 'viewer',
            _ => null,
          },
      connect: authority.connect,
      presence: presence,
    );
    return StudioRoom._(authority, presence, server, editorToken, viewerToken);
  }

  bool _closed = false;
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await server.close();
  }
}

/// One editor attachment. Pending writes survive restart before any transport send.
final class StudioCollaborationSession {
  final StudioScene scene;
  final SceneCollaborationClient client;
  final SceneCollaborationBinding binding;
  final OfflineSceneQueue offline;
  final ScenePresenceTransport presence;
  final SharedCameraFollower follower;
  final String sessionId, label;
  final Future<void> Function() closeTransport;
  final _JournalTransport _transport;
  bool _closed = false;
  StudioCollaborationSession._(
    this.scene,
    this.client,
    this.binding,
    this.offline,
    this.presence,
    this.follower,
    this.sessionId,
    this.label,
    this.closeTransport,
    this._transport,
  );

  static Future<StudioCollaborationSession> connect({
    required StudioScene scene,
    required SceneOperationTransport transport,
    required ScenePresenceTransport presence,
    required Directory directory,
    required String ownerId,
    required String label,
    Future<void> Function()? closeTransport,
  }) async {
    final initial = studioSnapshot(scene);
    final storeKey = sha256
        .convert(utf8.encode('${initial.sceneId}:${initial.epoch}:$ownerId'))
        .toString();
    final journal = FileSceneDocumentStore(
      File('${directory.path}/$storeKey.checkpoint'),
    );
    OfflineSceneState? saved;
    await journal.transact((source) async {
      if (source != null) saved = OfflineSceneState.decode(source);
      return (null, null);
    });
    if (saved != null &&
        (saved!.snapshot.sceneId != initial.sceneId ||
            saved!.snapshot.epoch != initial.epoch)) {
      throw const SceneSessionMismatch();
    }
    late SceneCollaborationClient client;
    final wrapper = transport is GuardedSceneOperationTransport
        ? _GuardedJournalTransport(transport, journal, () => client.snapshot!)
        : _JournalTransport(transport, journal, () => client.snapshot!);
    client = saved == null
        ? SceneCollaborationClient(
            transport: wrapper,
            sceneId: initial.sceneId,
            epoch: initial.epoch,
            nextOperationId: _nonce,
          )
        : SceneCollaborationClient.restore(
            transport: wrapper,
            snapshot: saved!.snapshot,
            pending: saved!.pending.firstOrNull,
            nextOperationId: _nonce,
          );
    try {
      await client.refresh();
      if (client.snapshot!.objects.length != scene.objects.length ||
          client.snapshot!.objects.keys.any(
            (id) =>
                id.source != scene.document.id ||
                !scene.objects.containsKey(id.key),
          )) {
        throw const SceneSessionMismatch();
      }
      await wrapper.checkpoint(client.snapshot!, client.pending);
      final offline = OfflineSceneQueue(
        store: FileSceneDocumentStore(
          File('${directory.path}/$storeKey.outbox'),
        ),
        transport: transport,
        sceneId: initial.sceneId,
        epoch: initial.epoch,
        ownerId: ownerId,
      );
      await offline.initialize(client.snapshot!);
      final binding = SceneCollaborationBinding(
        scene: scene.scene,
        client: client,
      );
      binding.rebind({
        for (final entry in scene.objects.entries)
          SceneObjectId(source: scene.document.id, key: entry.key): entry.value,
      });
      final follower = SharedCameraFollower(
        apply: (remote) {
          if (remote is! PerspectiveCamera) {
            throw StateError('Studio uses a perspective camera.');
          }
          scene.camera.batch(() {
            scene.camera.position = remote.position;
            scene.camera.target = remote.target;
            scene.camera.up = remote.up;
            scene.camera.fieldOfView = remote.fieldOfView;
            scene.camera.near = remote.near;
            scene.camera.far = remote.far;
            scene.camera.zoom = remote.zoom;
          });
        },
      );
      scene.history.clear();
      scene.tools.clearHistory();
      return StudioCollaborationSession._(
        scene,
        client,
        binding,
        offline,
        presence,
        follower,
        'session-${_nonce()}',
        label,
        closeTransport ?? () async {},
        wrapper,
      );
    } catch (_) {
      await client.close();
      await closeTransport?.call();
      rethrow;
    }
  }

  Future<void> refresh() async {
    if (client.isBusy) return;
    await client.refresh();
    await saveCheckpoint();
    follower.update(await presence.participants());
  }

  Future<void> publish(
    int sequence, {
    String? selectedId,
    bool shareCamera = false,
  }) => presence.publishPresence(
    sessionId: sessionId,
    label: label,
    sequence: sequence,
    camera: shareCamera ? SharedSceneCamera.capture(scene.camera) : null,
    selection: selectedId == null
        ? null
        : SceneObjectId(source: scene.document.id, key: selectedId),
  );

  Future<SceneOperationResult> transform(String id, SceneTransform pose) async {
    client.setTransform(
      SceneObjectId(source: scene.document.id, key: id),
      pose,
    );
    return retryPending();
  }

  Future<SceneOperationResult> visible(String id, bool visible) async {
    client.setVisible(
      SceneObjectId(source: scene.document.id, key: id),
      visible,
    );
    return retryPending();
  }

  Future<SceneOperationResult> undo(int revision) async {
    final inverse = await _transport.prepareUndo(
      revision: revision,
      operationId: _nonce(),
    );
    client.queueOperation(inverse);
    return retryPending();
  }

  Future<void> saveCheckpoint() => _transport.checkpoint(
    client.snapshot!,
    client.pending,
    conflict: client.conflict,
  );
  Future<SceneOperationResult> retryPending() async {
    final result = await client.flush();
    await saveCheckpoint();
    return result;
  }

  Future<void> acceptRemote() async {
    client.acceptRemote();
    await _transport.checkpoint(client.snapshot!, null);
  }

  Future<SceneOperationResult> keepLocal() async {
    client.keepLocal();
    return retryPending();
  }

  Future<void> queueTransform(String id, SceneTransform pose) async {
    final saved = await offline.read();
    final target = SceneObjectId(source: scene.document.id, key: id);
    final state = saved.snapshot.objects[target];
    if (state == null) throw const SceneSessionMismatch();
    await offline.enqueue(
      SceneOperation(
        sceneId: saved.snapshot.sceneId,
        epoch: saved.snapshot.epoch,
        operationId: _nonce(),
        objectId: target,
        field: SceneField.transform,
        expectedRevision: state.transformRevision,
        transform: pose,
      ),
    );
  }

  Future<OfflineSceneState> reconcile() async {
    final state = await offline.reconcile();
    await client.refresh();
    return state;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    follower.close();
    await binding.dispose();
    await client.close();
    try {
      await presence.leave(sessionId);
    } catch (_) {
      /* The lease expires if disconnected. */
    }
    await closeTransport();
    scene.history.clear();
    scene.tools.clearHistory();
  }
}

class _JournalTransport
    implements
        SceneOperationTransport,
        SceneUndoTransport,
        SceneCollaborationQueries {
  final SceneOperationTransport base;
  final SceneDocumentStore journal;
  final SceneSnapshot Function() snapshot;
  _JournalTransport(this.base, this.journal, this.snapshot);
  Future<void> checkpoint(
    SceneSnapshot state,
    SceneOperation? pending, {
    SceneOperationConflict? conflict,
  }) => journal.transact(
    (_) async => (
      null,
      OfflineSceneState(
        snapshot: state,
        pending: [?pending],
        conflict: conflict,
      ).encode(),
    ),
  );
  @override
  Future<SceneSnapshot> read() => base.read();
  @override
  Future<SceneOperationResult> submit(SceneOperation operation) =>
      _submit(operation);
  Future<SceneOperationResult> _submit(
    SceneOperation operation, [
    void Function()? guard,
  ]) async {
    await checkpoint(snapshot(), operation);
    final result = guard == null
        ? await base.submit(operation)
        : await (base as GuardedSceneOperationTransport).submitGuarded(
            operation,
            checkBeforeCommit: guard,
          );
    return result;
  }

  @override
  Future<SceneOperation> prepareUndo({
    required int revision,
    required String operationId,
  }) => (base as SceneUndoTransport).prepareUndo(
    revision: revision,
    operationId: operationId,
  );
  @override
  Future<SceneOperationResult> undo({
    required int revision,
    required String operationId,
  }) async =>
      submit(await prepareUndo(revision: revision, operationId: operationId));
  @override
  Future<bool> allows(SceneOperation operation) =>
      (base as SceneCollaborationQueries).allows(operation);
  @override
  Future<SceneHistoryPage> history({
    required int expectedRevision,
    int afterRevision = 0,
    int limit = 50,
  }) => (base as SceneCollaborationQueries).history(
    expectedRevision: expectedRevision,
    afterRevision: afterRevision,
    limit: limit,
  );
}

final class _GuardedJournalTransport extends _JournalTransport
    implements GuardedSceneOperationTransport {
  _GuardedJournalTransport(super.base, super.journal, super.snapshot);
  @override
  Future<SceneOperationResult> submitGuarded(
    SceneOperation operation, {
    required void Function() checkBeforeCommit,
  }) => _submit(operation, checkBeforeCommit);
}

/// The shared provider keeps its schemas and behavior. Network writes remain
/// unavailable to agents until the service supports atomic cancellation guards.
final class StudioCollaborationAgentProvider extends AgentProvider {
  final StudioCollaborationSession session;
  late final delegate = CollaborationAgentProvider(
    client: session.client,
    binding: session.binding,
    documentId: session.scene.document.id,
    instanceId: session.sessionId,
    presence: session.presence,
    offline: session.offline,
    cameraFollower: session.follower,
  );
  StudioCollaborationAgentProvider(this.session);
  static const _needsGuard = {
    'set_transform',
    'set_visibility',
    'undo',
    'keep_local',
    'retry_pending',
  };
  bool get _guarded =>
      session.client.transport is GuardedSceneOperationTransport;
  @override
  String get id => delegate.id;
  @override
  String get version => delegate.version;
  @override
  String get instanceId => delegate.instanceId;
  @override
  int get revision => delegate.revision;
  @override
  Map<String, Object?> get capabilities => {
    ...delegate.capabilities,
    'durablePendingWrites': true,
  };
  @override
  List<AgentTool> get tools => delegate.tools
      .where((tool) => _guarded || !_needsGuard.contains(tool.name))
      .toList();
  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    if (!_guarded && _needsGuard.contains(tool)) {
      return AgentResult(AgentStatus.unsupported);
    }
    try {
      return await delegate.invoke(tool, arguments, context);
    } finally {
      if (!session.client.isClosed &&
          !session.client.isBusy &&
          session.client.snapshot != null) {
        await session.saveCheckpoint();
      }
    }
  }
}
