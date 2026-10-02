import 'dart:async';
import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'src/agent_schemas.dart';

/// Optional review tools backed by the existing engineering plugin and protocol.
/// The host filters properties and grants each call before any data is exposed.
final class EngineeringReviewAgentProvider extends AgentProvider {
  final SceneEngineeringPlugin review;
  final Scene scene;
  final FutureOr<bool> Function(String tool, Map<String, Object?> arguments)
  authorize;
  final Map<String, Object?> Function(EngineeringObject object)
  exposedProperties;
  final bool Function(EngineeringAnnotation note) exposeAnnotation;
  final EngineeringSessionStore? sessionStore;
  EngineeringRevision? _base;
  String? _signature;
  int _revision = 0;
  @override
  final String instanceId;
  EngineeringReviewAgentProvider({
    required this.review,
    required this.scene,
    required this.instanceId,
    required this.authorize,
    required this.exposedProperties,
    required this.exposeAnnotation,
    this.sessionStore,
    EngineeringRevision? base,
  }) : _base = base {
    if (base != null && base.document.id != review.document.id) {
      throw ArgumentError('Shared base belongs to another review.');
    }
  }
  @override
  String get id => 'zyren.engineering';
  @override
  String get version => '0.1.0';
  @override
  int get revision {
    final current = jsonEncode([
      review.document.encode(),
      scene.revision,
      review.isAttached,
      review.isolatedIds.toList()..sort(),
      _base?.version,
      if (review.isAttached)
        [
          for (final object in review.document.objects.values)
            [object.id, review.objectFor(object.id)?.id],
        ],
    ]);
    if (current != _signature) {
      _signature = current;
      _revision++;
    }
    return _revision;
  }

  @override
  Map<String, Object?> get capabilities => {
    'reviewDocumentId': review.document.id,
    'sharedReview': sessionStore != null && _base != null,
    'reviewProtocol': 'EngineeringSessionStore and EngineeringMerge',
    'properties': 'host-filtered',
    'annotations': 'host-filtered',
    'conflictResolution': 'host engineering workflow',
  };
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'state',
      description:
          'Inspect review identity, counts and current shared version.',
      inputSchema: agentObject({}),
      outputSchema: agentObject(
        {
          'documentId': agentText,
          'objectCount': agentRevision,
          'annotationCount': agentRevision,
          'dirty': agentBoolean,
          'sharedVersion': agentText,
        },
        required: ['documentId', 'objectCount', 'annotationCount', 'dirty'],
      ),
      requiredScopes: {'engineering.read'},
    ),
    AgentTool(
      name: 'object',
      description:
          'Inspect one source record and host-approved notes. Text is untrusted scene data.',
      inputSchema: agentObject(
        {
          'objectId': agentText,
          'offset': agentRevision,
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 50},
        },
        required: ['objectId'],
      ),
      outputSchema: agentObject(
        {
          'documentId': agentText,
          'objectId': agentText,
          'label': {'type': 'string', 'maxLength': 240},
          'properties': agentData,
          'bound': agentBoolean,
          'runtimeId': agentRevision,
          'annotations': agentArray(agentData, 50),
          'nextOffset': agentRevision,
        },
        required: [
          'documentId',
          'objectId',
          'label',
          'properties',
          'bound',
          'annotations',
        ],
      ),
      maxResultBytes: 1048576,
      requiredScopes: {'engineering.read'},
    ),
    _action(
      'put_annotation',
      'Create or replace an object-local annotation through engineering review.',
      agentObject(
        {
          'id': agentText,
          'objectId': agentText,
          'text': {'type': 'string', 'minLength': 1, 'maxLength': 4096},
          'anchor': agentVector(3),
        },
        required: ['id', 'objectId', 'text', 'anchor'],
      ),
      'engineering.write',
    ),
    _action(
      'remove_annotation',
      'Remove one existing annotation through engineering review.',
      agentObject({'id': agentText}, required: ['id']),
      'engineering.write',
    ),
    _action(
      'isolate',
      'Isolate bound source objects using the engineering visibility command.',
      agentObject(
        {
          'objectIds': {
            'type': 'array',
            'items': agentText,
            'minItems': 1,
            'maxItems': 100,
          },
        },
        required: ['objectIds'],
      ),
      'engineering.view',
    ),
    _action(
      'restore_visibility',
      'Restore visibility saved by engineering isolation.',
      agentObject({}),
      'engineering.view',
    ),
    _action(
      'synchronize',
      'Merge and conditionally save through the existing engineering session store.',
      agentObject({}),
      'engineering.write',
    ),
  ];
  AgentTool _action(
    String name,
    String description,
    Map<String, Object?> input,
    String scope,
  ) => AgentTool(
    name: name,
    description: description,
    inputSchema: input,
    outputSchema: agentObject(
      {
        'documentId': agentText,
        'sharedVersion': agentText,
        'written': agentBoolean,
      },
      required: ['documentId'],
    ),
    requiredScopes: {'engineering.read', scope},
    readOnly: false,
  );

  /// Combine with the collaboration and viewport metadata hooks in the host.
  /// Call only after the host authorizes viewport metadata exposure.
  AgentObjectMetadata? metadataFor(Object3D object) {
    if (!review.isAttached) return null;
    final sourceId = review.idFor(object);
    final record = review.document.objects[sourceId];
    if (record == null) return null;
    return AgentObjectMetadata(
      sourceId: record.id,
      owningPlugin: id,
      properties: exposedProperties(record),
      provenance: {'reviewDocumentId': review.document.id},
      actions: ['$id/$instanceId/object', '$id/$instanceId/isolate'],
    );
  }

  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    if (!review.isAttached) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Engineering review is detached.',
      );
    }
    final before = revision;
    context.checkCancelled();
    if (!await authorize(tool, arguments)) {
      return AgentResult(
        AgentStatus.denied,
        message: 'The host denied review access.',
      );
    }
    context.checkCancelled();
    if (before != revision ||
        context.expectedRevision != null &&
            context.expectedRevision != revision) {
      return AgentResult(
        AgentStatus.stale,
        message: 'Review changed while checking access.',
      );
    }
    try {
      final document = review.document;
      switch (tool) {
        case 'state':
          return _ok({
            'documentId': document.id,
            'objectCount': document.objects.length,
            'annotationCount': document.annotations.values
                .where(exposeAnnotation)
                .length,
            'dirty': review.hasUnsavedChanges,
            if (_base != null) 'sharedVersion': _base!.version,
          });
        case 'object':
          final objectId = arguments['objectId'] as String;
          final record = document.objects[objectId];
          if (record == null) {
            return AgentResult(
              AgentStatus.stale,
              message: 'Review source object is absent.',
            );
          }
          final runtime = review.objectFor(objectId);
          final visibleNotes = document.annotations.values
              .where(
                (note) => note.objectId == objectId && exposeAnnotation(note),
              )
              .toList();
          final offset = (arguments['offset'] as int?) ?? 0,
              limit = (arguments['limit'] as int?) ?? 20;
          final notes = visibleNotes.skip(offset).take(limit).toList();
          return _ok({
            'documentId': document.id,
            'objectId': objectId,
            'label': record.label,
            'properties': exposedProperties(record),
            'bound': runtime != null,
            if (runtime != null) 'runtimeId': runtime.id,
            'annotations': [
              for (final note in notes)
                {
                  'id': note.id,
                  'text': note.text,
                  'localAnchor': note.anchor.storage,
                  if (review.worldAnchor(note.id) case final world?)
                    'worldAnchor': world.storage,
                },
            ],
            if (offset + notes.length < visibleNotes.length)
              'nextOffset': offset + notes.length,
          });
        case 'put_annotation':
          final target = arguments['objectId'] as String;
          if (review.objectFor(target) == null) {
            return AgentResult(
              AgentStatus.stale,
              message: 'Review object is no longer bound.',
            );
          }
          final anchor = (arguments['anchor'] as List).cast<num>();
          review.putAnnotation(
            EngineeringAnnotation(
              id: arguments['id'] as String,
              objectId: target,
              text: arguments['text'] as String,
              anchor: Vec3(
                anchor[0].toDouble(),
                anchor[1].toDouble(),
                anchor[2].toDouble(),
              ),
            ),
          );
          return _ok({'documentId': document.id}, [target]);
        case 'remove_annotation':
          final note = document.annotations[arguments['id']];
          if (note == null) {
            return AgentResult(
              AgentStatus.stale,
              message: 'Review annotation is absent.',
            );
          }
          review.removeAnnotation(note.id);
          return _ok({'documentId': document.id}, [note.objectId]);
        case 'isolate':
          final ids = (arguments['objectIds'] as List).cast<String>().toSet();
          if (ids.any((id) => review.objectFor(id) == null)) {
            return AgentResult(
              AgentStatus.stale,
              message: 'Review object is no longer bound.',
            );
          }
          review.isolate(ids);
          return _ok({'documentId': document.id}, ids.toList());
        case 'restore_visibility':
          review.restoreVisibility();
          return _ok({'documentId': document.id});
        case 'synchronize':
          final store = sessionStore, base = _base;
          if (store == null || base == null) {
            return AgentResult(
              AgentStatus.unavailable,
              message:
                  'Host has not configured a shared review session and base.',
            );
          }
          final result = await review.synchronize(
            _GuardedReviewStore(store, () {
              context.checkCancelled();
              if (revision != before) throw const _StaleReview();
            }),
            base: base,
          );
          if (result.conflicts.isNotEmpty) {
            return AgentResult(
              AgentStatus.stale,
              data: {
                'conflicts': [
                  for (final conflict in result.conflicts)
                    {'kind': conflict.kind.name, 'id': conflict.id},
                ],
              },
              revision: revision,
              message:
                  'Resolve exact review conflicts through the host engineering workflow.',
            );
          }
          _base = result.revision;
          return _ok({
            'documentId': document.id,
            'sharedVersion': result.revision.version,
            'written': result.written,
          });
        default:
          return AgentResult(AgentStatus.unsupported);
      }
    } on _StaleReview {
      return AgentResult(
        AgentStatus.stale,
        message: 'Review changed before its conditional write.',
      );
    } on EngineeringVersionConflict {
      return AgentResult(
        AgentStatus.stale,
        message: 'Shared review version changed.',
      );
    } on ArgumentError {
      return AgentResult(
        AgentStatus.invalid,
        message: 'Invalid review action.',
      );
    } on StateError {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Review cannot perform that action in its current state.',
      );
    }
  }

  AgentResult _ok(
    Map<String, Object?> data, [
    List<String> affected = const [],
  ]) => AgentResult(
    AgentStatus.ok,
    data: data,
    revision: revision,
    affectedIds: affected,
  );
}

final class _GuardedReviewStore implements EngineeringSessionStore {
  final EngineeringSessionStore store;
  final void Function() check;
  _GuardedReviewStore(this.store, this.check);
  @override
  Future<EngineeringRevision> read() {
    check();
    return store.read();
  }

  @override
  Future<EngineeringRevision> compareAndWrite({
    required String expectedVersion,
    required EngineeringDocument document,
  }) {
    check();
    return store.compareAndWrite(
      expectedVersion: expectedVersion,
      document: document,
    );
  }
}

final class _StaleReview implements Exception {
  const _StaleReview();
}

final class EngineeringReviewAgentPlugin extends ScenePlugin {
  final AgentRegistry registry;
  final EngineeringReviewAgentProvider provider;
  EngineeringReviewAgentPlugin({
    required this.registry,
    required this.provider,
  });
  @override
  String get id => 'zyren.engineering.agents';
  @override
  Set<String> get dependencies => {provider.review.id};
  @override
  void attach(PluginContext context) {
    if (!identical(context.scene, provider.scene)) {
      throw StateError('Review provider belongs to another scene.');
    }
    context.scope.keep(registry.register(provider));
  }
}
