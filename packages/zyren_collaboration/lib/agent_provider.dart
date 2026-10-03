import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'src/agent_schemas.dart';
import 'zyren_collaboration.dart';

/// Shared runtime tools for one client and optional scene binding.
/// Register through [SceneCollaborationAgentPlugin] for attachment cleanup.
final class CollaborationAgentProvider extends AgentProvider {
  final SceneCollaborationClient client;
  final SceneCollaborationBinding? binding;
  final SceneCollaborationQueries? queries;
  final ScenePresenceTransport? presence;
  final OfflineSceneQueue? offline;
  final SharedCameraFollower? cameraFollower;
  final String documentId;
  @override
  final String instanceId;
  CollaborationAgentProvider({
    required this.client,
    required this.instanceId,
    required this.documentId,
    this.binding,
    this.presence,
    this.offline,
    this.cameraFollower,
    SceneCollaborationQueries? queries,
  }) : queries =
           queries ??
           (client.transport is SceneCollaborationQueries
               ? client.transport as SceneCollaborationQueries
               : null) {
    if (binding != null && !identical(binding!.client, client)) {
      throw ArgumentError('Agent provider and binding must share a client.');
    }
  }
  @override
  String get id => 'zyren.collaboration';
  @override
  String get version => '0.1.0';
  @override
  int get revision =>
      client.stateRevision +
      (binding == null ? 0 : binding!.revision + binding!.scene.revision);
  @override
  Map<String, Object?> get capabilities => {
    'sceneId': client.sceneId,
    'documentId': documentId,
    'epoch': client.epoch,
    'history': queries != null,
    'presence': presence == null ? 'unavailable' : 'leased',
    'sharedCameras': cameraFollower == null ? 'unsupported' : 'opt-in',
    'durableOfflineQueue': offline != null,
    'sharedUndo': client.transport is SceneUndoTransport,
    'guardedActions': client.transport is GuardedSceneOperationTransport,
    'viewportEvidence':
        'Use the shared viewport provider for frame and camera context.',
  };

  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'state',
      description:
          'Inspect acknowledged revisions, pending edits and conflicts.',
      inputSchema: agentObject({}),
      outputSchema: agentObject(
        {
          'sceneId': agentText,
          'documentId': agentText,
          'epoch': agentText,
          'sceneRevision': agentRevision,
          'remoteSceneRevision': agentRevision,
          'objectCount': agentRevision,
          'pending': agentData,
          'conflict': agentData,
        },
        required: [
          'sceneId',
          'documentId',
          'epoch',
          'sceneRevision',
          'objectCount',
        ],
      ),
      requiredScopes: {'collaboration.read'},
    ),
    AgentTool(
      name: 'objects',
      description:
          'List stable source objects, runtime bindings and field revisions.',
      inputSchema: agentPageInput,
      outputSchema: agentObject(
        {'objects': agentArray(agentData, 50), 'nextOffset': agentRevision},
        required: ['objects'],
      ),
      requiredScopes: {'collaboration.read'},
    ),
    AgentTool(
      name: 'history',
      description:
          'Read a bounded page of accepted operations at the acknowledged scene revision.',
      inputSchema: agentObject({
        'afterRevision': agentRevision,
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 50},
      }),
      outputSchema: agentObject(
        {
          'sceneRevision': agentRevision,
          'records': agentArray(agentData, 50),
          'nextAfterRevision': agentRevision,
        },
        required: ['sceneRevision', 'records'],
      ),
      maxResultBytes: 1048576,
      requiredScopes: {'collaboration.read'},
    ),
    AgentTool(
      name: 'presence',
      description: 'Report whether this session has a presence service.',
      inputSchema: agentObject({}),
      outputSchema: agentData,
      requiredScopes: {'collaboration.read'},
    ),
    AgentTool(
      name: 'check_operation',
      description:
          'Check host permission for an exact schema-1 operation. Commit checks still apply.',
      inputSchema: agentObject(
        {
          'operation': {
            'type': 'string',
            'maxLength': SceneOperation.maxCharacters,
          },
        },
        required: ['operation'],
      ),
      outputSchema: agentObject(
        {'allowed': agentBoolean, 'operationId': agentText},
        required: ['allowed', 'operationId'],
      ),
      requiredScopes: {'collaboration.read'},
    ),
    _action(
      'undo',
      'Undo your accepted edit only while its field revision is unchanged.',
      agentObject({'revision': agentRevision}, required: ['revision']),
    ),
    AgentTool(
      name: 'offline_state',
      description: 'Inspect the persistent outbox and exact conflicts.',
      inputSchema: agentObject({}),
      outputSchema: agentData,
      requiredScopes: {'collaboration.read'},
    ),
    AgentTool(
      name: 'reconcile',
      description:
          'Retry saved operations without rebasing and stop on conflict.',
      inputSchema: agentObject({}),
      outputSchema: agentData,
      readOnly: false,
      requiredScopes: {'collaboration.read', 'collaboration.write'},
    ),
    for (final name in ['offline_keep_local', 'offline_accept_remote'])
      AgentTool(
        name: name,
        description: 'Resolve the exact persistent conflict you reviewed.',
        inputSchema: agentObject(
          {
            'operationId': agentText,
            'sceneRevision': agentRevision,
            'fieldRevision': agentRevision,
          },
          required: ['operationId', 'sceneRevision', 'fieldRevision'],
        ),
        outputSchema: agentData,
        readOnly: false,
        requiredScopes: {'collaboration.read', 'collaboration.write'},
      ),
    AgentTool(
      name: 'follow_camera',
      description:
          'Explicitly follow a currently leased camera. Local navigation stops following.',
      inputSchema: agentObject(
        {'sessionId': agentText},
        required: ['sessionId'],
      ),
      outputSchema: agentData,
      readOnly: false,
      requiredScopes: {'collaboration.read', 'collaboration.camera'},
    ),
    AgentTool(
      name: 'stop_following',
      description: 'Stop following a shared camera.',
      inputSchema: agentObject({}),
      outputSchema: agentData,
      readOnly: false,
      requiredScopes: {'collaboration.read', 'collaboration.camera'},
    ),
    _action(
      'set_transform',
      'Replace an object local transform through the shared scene client.',
      agentObject(
        {
          ...agentTarget,
          'position': agentVector(3),
          'rotation': agentVector(4),
          'scale': agentVector(3),
        },
        required: ['source', 'key', 'position', 'rotation', 'scale'],
      ),
    ),
    _action(
      'set_visibility',
      'Set object visibility through the shared scene client.',
      agentObject(
        {...agentTarget, 'visible': agentBoolean},
        required: ['source', 'key', 'visible'],
      ),
    ),
    _action(
      'refresh',
      'Read current shared state and apply it to the bound scene.',
      agentObject({}),
    ),
    _action(
      'retry_pending',
      'Retry the exact retained operation after a transport failure.',
      agentObject({}),
    ),
    _action(
      'keep_local',
      'Submit the local edit against the exact revision reported in its conflict.',
      agentObject({}),
    ),
    _action(
      'accept_remote',
      'Discard a confirmed conflicting local edit.',
      agentObject({}),
    ),
  ];

  AgentTool _action(
    String name,
    String description,
    Map<String, Object?> input,
  ) => AgentTool(
    name: name,
    description: description,
    inputSchema: input,
    outputSchema: agentObject(
      {
        'sceneRevision': agentRevision,
        'committedRevision': agentRevision,
        'duplicate': agentBoolean,
        'pending': agentBoolean,
      },
      required: ['sceneRevision', 'pending'],
    ),
    readOnly: false,
    requiredScopes: {'collaboration.read', 'collaboration.write'},
  );

  /// Supply this to the shared viewport metadata hook to correlate rich hits.
  /// Geometry and rendered visibility evidence remain the viewport provider's job.
  AgentObjectMetadata? metadataFor(Object3D object) {
    final snapshot = client.snapshot;
    if (snapshot == null || binding == null || binding!.isClosed) return null;
    for (final entry in snapshot.objects.entries) {
      if (!identical(binding!.objectFor(entry.key), object)) continue;
      return AgentObjectMetadata(
        sourceId: entry.key.toString(),
        owningPlugin: id,
        properties: {
          'transformRevision': entry.value.transformRevision,
          'visibilityRevision': entry.value.visibilityRevision,
        },
        provenance: {
          'sceneId': client.sceneId,
          'documentId': documentId,
          'epoch': client.epoch,
          'source': entry.key.source,
          'key': entry.key.key,
          'sceneRevision': snapshot.revision,
        },
        actions: [
          '$id/$instanceId/check_operation',
          '$id/$instanceId/set_transform',
          '$id/$instanceId/set_visibility',
        ],
      );
    }
    return null;
  }

  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    if (client.isClosed || (binding?.isClosed ?? false)) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Scene client or binding is closed.',
      );
    }
    final snapshot = client.snapshot;
    if (snapshot == null) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Read the scene through the host before using its tools.',
      );
    }
    context.checkCancelled();
    try {
      final remote = await client.transport.read();
      context.checkCancelled();
      if (remote.sceneId != client.sceneId || remote.epoch != client.epoch) {
        throw const SceneSessionMismatch();
      }
      switch (tool) {
        case 'state':
          return _ok({
            'sceneId': client.sceneId,
            'documentId': documentId,
            'epoch': client.epoch,
            'sceneRevision': snapshot.revision,
            'remoteSceneRevision': remote.revision,
            'objectCount': snapshot.objects.length,
            if (client.pending case final operation?)
              'pending': jsonDecode(operation.encode()),
            if (client.conflict case final conflict?)
              'conflict': {
                'operation': jsonDecode(conflict.operation.encode()),
                'current': conflict.current.toJson(),
                'actualRevision': conflict.actualRevision,
              },
          });
        case 'objects':
          final offset = (arguments['offset'] as int?) ?? 0;
          final limit = (arguments['limit'] as int?) ?? 20;
          final page = snapshot.objects.values
              .skip(offset)
              .take(limit)
              .toList();
          return _ok({
            'objects': [
              for (final object in page)
                {
                  ...object.toJson(),
                  if (binding?.objectFor(object.id) case final runtime?)
                    'runtimeId': runtime.id,
                  'binding': binding?.objectFor(object.id) == null
                      ? 'unbound'
                      : 'bound',
                },
            ],
            if (offset + page.length < snapshot.objects.length)
              'nextOffset': offset + page.length,
          });
        case 'offline_state':
          if (offline == null) return AgentResult(AgentStatus.unavailable);
          final state = await offline!.read();
          context.checkCancelled();
          return _ok(jsonDecode(state.encode()) as Map<String, dynamic>);
        case 'presence':
          if (presence != null) {
            final participants = await presence!.participants();
            context.checkCancelled();
            return _ok({
              'participants': participants.map((p) => p.toJson()).toList(),
              'following': cameraFollower?.sessionId,
            });
          }
          return AgentResult(
            AgentStatus.unavailable,
            message:
                'This transport has no presence service. Participant count is unknown.',
          );
        case 'history':
          final service = queries;
          if (service == null) {
            return AgentResult(
              AgentStatus.unsupported,
              message: 'Transport has no operation history query.',
            );
          }
          final page = await service.history(
            expectedRevision: snapshot.revision,
            afterRevision: (arguments['afterRevision'] as int?) ?? 0,
            limit: (arguments['limit'] as int?) ?? 20,
          );
          context.checkCancelled();
          return _ok({
            'sceneRevision': page.sceneRevision,
            'records': [
              for (final entry in page.records)
                {
                  'revision': entry.revision,
                  'operation': jsonDecode(entry.operation.encode()),
                },
            ],
            if (page.nextAfterRevision != null)
              'nextAfterRevision': page.nextAfterRevision,
          });
        case 'check_operation':
          final service = queries;
          if (service == null) {
            return AgentResult(
              AgentStatus.unsupported,
              message: 'Transport has no permission preview.',
            );
          }
          final operation = SceneOperation.decode(
            arguments['operation'] as String,
          );
          final allowed = await service.allows(operation);
          context.checkCancelled();
          return _ok({
            'allowed': allowed,
            'operationId': operation.operationId,
          });
      }
      if (context.expectedRevision != revision) {
        return AgentResult(AgentStatus.stale, message: 'Client state changed.');
      }
      if (tool == 'offline_keep_local' || tool == 'offline_accept_remote') {
        if (offline == null) return AgentResult(AgentStatus.unavailable);
        final state = await offline!.read();
        final conflict = state.conflict;
        context.checkCancelled();
        if (context.expectedRevision != revision ||
            conflict == null ||
            conflict.operation.operationId != arguments['operationId'] ||
            state.snapshot.revision != arguments['sceneRevision'] ||
            conflict.actualRevision != arguments['fieldRevision']) {
          throw const SceneRevisionMismatch();
        }
        if (tool == 'offline_keep_local') {
          await offline!.keepLocal(
            client.nextOperationId(),
            reviewed: conflict,
          );
        } else {
          await offline!.acceptRemote(reviewed: conflict);
        }
        return _ok({'pending': (await offline!.read()).pending.length});
      }
      if (tool == 'reconcile') {
        if (offline == null) return AgentResult(AgentStatus.unavailable);
        context.checkCancelled();
        final state = await offline!.reconcile(
          checkBeforeSend: context.checkCancelled,
        );
        context.checkCancelled();
        await client.refresh(checkBeforeApply: context.checkCancelled);
        return _ok(jsonDecode(state.encode()) as Map<String, dynamic>);
      }
      if (tool == 'follow_camera' || tool == 'stop_following') {
        if (cameraFollower == null || presence == null) {
          return AgentResult(AgentStatus.unavailable);
        }
        if (tool == 'stop_following') {
          cameraFollower!.stop();
          return _ok({'following': null});
        }
        final participants = await presence!.participants();
        context.checkCancelled();
        if (context.expectedRevision != revision) {
          throw const SceneRevisionMismatch();
        }
        final session = arguments['sessionId'] as String;
        if (!participants.any(
          (p) =>
              p.sessionId == session &&
              p.camera != null &&
              p.expiresAt.isAfter(DateTime.now()),
        )) {
          return AgentResult(
            AgentStatus.unavailable,
            message: 'Participant has no current camera lease.',
          );
        }
        cameraFollower!.follow(session);
        cameraFollower!.update(participants);
        return _ok({'following': cameraFollower!.sessionId});
      }
      if (tool == 'refresh') {
        final before = revision;
        await client.refresh(
          checkBeforeApply: () {
            context.checkCancelled();
            if (revision != before) throw const SceneRevisionMismatch();
          },
        );
        return _ok({
          'sceneRevision': client.snapshot!.revision,
          'pending': client.pending != null,
        });
      }
      if (tool == 'accept_remote') {
        client.acceptRemote();
        return _ok({
          'sceneRevision': client.snapshot!.revision,
          'pending': false,
        });
      }
      if (client.transport is! GuardedSceneOperationTransport) {
        return AgentResult(
          AgentStatus.unsupported,
          message:
              'Agent edits require a transport with precommit cancellation checks.',
        );
      }
      switch (tool) {
        case 'undo':
          if (client.transport is! SceneUndoTransport) {
            return AgentResult(AgentStatus.unsupported);
          }
          final before = revision;
          final operation = await (client.transport as SceneUndoTransport)
              .prepareUndo(
                revision: arguments['revision'] as int,
                operationId: client.nextOperationId(),
              );
          context.checkCancelled();
          if (revision != before) throw const SceneRevisionMismatch();
          if (binding != null &&
              binding!.objectFor(operation.objectId) == null) {
            throw const SceneRevisionMismatch();
          }
          client.queueOperation(operation);
        case 'set_transform':
        case 'set_visibility':
          final target = SceneObjectId(
            source: arguments['source'] as String,
            key: arguments['key'] as String,
          );
          if (!snapshot.objects.containsKey(target) ||
              binding != null && binding!.objectFor(target) == null) {
            return AgentResult(
              AgentStatus.stale,
              message: 'Source target is absent or no longer bound.',
            );
          }
          if (tool == 'set_visibility') {
            client.setVisible(target, arguments['visible'] as bool);
          } else {
            client.setTransform(
              target,
              SceneTransform.fromJson({
                'position': arguments['position'],
                'rotation': arguments['rotation'],
                'scale': arguments['scale'],
              }),
            );
          }
        case 'keep_local':
          client.keepLocal();
        case 'retry_pending':
          if (client.pending == null) {
            return AgentResult(
              AgentStatus.empty,
              data: {'sceneRevision': snapshot.revision, 'pending': false},
              revision: revision,
            );
          }
        default:
          return AgentResult(AgentStatus.unsupported);
      }
      final preparedRevision = revision;
      final target = client.pending!.objectId;
      final result = await client.flush(
        checkBeforeCommit: () {
          context.checkCancelled();
          if (revision != preparedRevision ||
              binding != null && binding!.objectFor(target) == null) {
            throw const SceneRevisionMismatch();
          }
        },
      );
      if (result is SceneOperationConflict) {
        return AgentResult(
          AgentStatus.stale,
          data: {
            'conflict': {
              'operation': jsonDecode(result.operation.encode()),
              'current': result.current.toJson(),
            },
          },
          message:
              'Inspect the conflict and choose keep_local or accept_remote.',
          revision: revision,
        );
      }
      final accepted = result as SceneOperationAccepted;
      return AgentResult(
        AgentStatus.ok,
        data: {
          'sceneRevision': client.snapshot!.revision,
          'committedRevision': accepted.committedRevision,
          'duplicate': accepted.duplicate,
          'pending': false,
        },
        revision: revision,
        affectedIds: [target.toString()],
      );
    } on SceneAccessDenied {
      return AgentResult(
        AgentStatus.denied,
        message: 'The host denied scene access.',
      );
    } on SceneRevisionMismatch {
      return AgentResult(
        AgentStatus.stale,
        message: 'Scene changed before the operation completed.',
      );
    } on SceneSessionMismatch {
      return AgentResult(
        AgentStatus.stale,
        message: 'Scene identity or epoch changed.',
      );
    } on SceneReceiptCapacityExceeded {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Operation receipt capacity is full.',
      );
    } on FormatException {
      return AgentResult(
        AgentStatus.invalid,
        message: 'Invalid scene operation.',
      );
    } on ArgumentError {
      return AgentResult(AgentStatus.invalid, message: 'Invalid scene edit.');
    } on StateError {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Client cannot perform that action in its current state.',
      );
    }
  }

  AgentResult _ok(Map<String, Object?> data) =>
      AgentResult(AgentStatus.ok, data: data, revision: revision);
}

final class SceneCollaborationAgentPlugin extends ScenePlugin {
  final SceneCollaborationPlugin collaboration;
  final AgentRegistry registry;
  final String instanceId, documentId;
  CollaborationAgentProvider? provider;
  SceneCollaborationAgentPlugin({
    required this.collaboration,
    required this.registry,
    required this.instanceId,
    required this.documentId,
  });
  @override
  String get id => 'zyren.collaboration.agents';
  @override
  Set<String> get dependencies => {collaboration.id};
  @override
  void attach(PluginContext context) {
    final bound = collaboration.binding;
    if (!identical(bound.scene, context.scene)) {
      throw StateError('Provider must attach to its bound scene.');
    }
    final instance = CollaborationAgentProvider(
      client: collaboration.client,
      binding: bound,
      instanceId: instanceId,
      documentId: documentId,
    );
    context.scope.keep(registry.register(instance));
    provider = instance;
  }

  @override
  void detach(PluginContext context) {
    provider = null;
  }
}
