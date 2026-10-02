/// Optional imported rig and clip inspection. Playback uses TimelineAgentProvider.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_gltf/zyren_gltf.dart';

final class ModelAnimationAgentProvider extends AgentProvider {
  final ModelInstance model;
  @override
  final String instanceId;
  final String sourceId;
  final int Function() readRevision;
  final bool Function() isAvailable;
  ModelAnimationAgentProvider({
    required this.model,
    required this.instanceId,
    required this.sourceId,
    required this.readRevision,
    required this.isAvailable,
  });
  @override
  String get id => 'zyren.gltf-animation';
  @override
  String get version => '0.1.0';
  @override
  int get revision => readRevision();
  Registration register(AgentRegistry registry, AttachmentScope scope) =>
      scope.keep(registry.register(this));
  @override
  Map<String, Object?> get capabilities => {
    'sourceId': sourceId,
    'nodeIdentity': 'source-glTF-node-index',
    'runtimeIdentity': 'isolate-object-id',
    'rigCoverage': 'imported-nodes-local-transforms',
    'skinInfluences': 'not-exposed',
    'playbackProvider': 'zyren.timeline',
    'timeUnits': 'seconds',
  };

  /// Resolves imported descendants to source glTF node indices.
  AgentObjectMetadata? describeObject(Object3D object) {
    if (!isAvailable()) return null;
    for (
      Object3D? node = object;
      node != null && node != model;
      node = node.parent
    ) {
      for (final entry in model.nodes.entries) {
        if (identical(entry.value, node)) {
          return AgentObjectMetadata(
            sourceId: '$sourceId#node/${entry.key}',
            semanticType: 'imported-animation-node',
            owningPlugin: id,
            properties: {
              'sourceNodeIndex': entry.key,
              'modelRuntimeId': model.id,
            },
            provenance: {'modelSourceId': sourceId, 'indexSpace': 'glTF-node'},
            actions: ['$id/$instanceId/inspect'],
          );
        }
      }
    }
    return null;
  }

  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'inspect',
      description: 'Page imported nodes or animation clips by source index.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'collection': {
            'type': 'string',
            'enum': ['nodes', 'clips'],
          },
          'offset': {'type': 'integer', 'minimum': 0},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 32},
        },
        'required': ['collection'],
        'additionalProperties': false,
      },
      outputSchema: const {
        'type': 'object',
        'properties': {
          'sourceId': {'type': 'string'},
          'runtimeId': {'type': 'integer'},
          'total': {'type': 'integer'},
          'items': {
            'type': 'array',
            'items': {'type': 'object'},
            'maxItems': 32,
          },
        },
        'required': ['sourceId', 'runtimeId', 'total', 'items'],
        'additionalProperties': false,
      },
    ),
  ];
  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    if (!isAvailable()) {
      return AgentResult(
        AgentStatus.stale,
        message: 'Imported model was removed.',
      );
    }
    if (tool != 'inspect') return AgentResult(AgentStatus.unsupported);
    final offset = arguments['offset'] as int? ?? 0,
        limit = arguments['limit'] as int? ?? 32;
    final nodes = arguments['collection'] == 'nodes';
    return AgentResult(
      AgentStatus.ok,
      data: {
        'sourceId': sourceId,
        'runtimeId': model.id,
        'total': nodes ? model.nodes.length : model.animations.length,
        'items': nodes
            ? [
                for (final e in model.nodes.entries.skip(offset).take(limit))
                  {
                    'sourceNodeIndex': e.key,
                    'runtimeId': e.value.id,
                    'parentRuntimeId': e.value.parent?.id,
                    'position': e.value.position.storage,
                    'scale': e.value.scale.storage,
                    'rotation': [
                      e.value.quaternion.x,
                      e.value.quaternion.y,
                      e.value.quaternion.z,
                      e.value.quaternion.w,
                    ],
                  },
              ]
            : [
                for (
                  var i = offset;
                  i < model.animations.length && i < offset + limit;
                  i++
                )
                  {
                    'sourceClipIndex': i,
                    'name': model.animations[i].name,
                    'durationSeconds':
                        model.animations[i].duration.inMicroseconds / 1e6,
                    'channelCount': model.animations[i].channels.length,
                  },
              ],
      },
      revision: revision,
    );
  }
}
