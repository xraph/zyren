/// Optional character runtime tools using the shared agent registry.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_characters.dart';

/// A synchronous host command gateway owns history and increments host revision.
typedef CharacterAgentCommand =
    void Function(String name, void Function() apply);

final class CharacterAgentProvider extends AgentProvider {
  final CharacterAnimationPlugin character;
  @override
  final String instanceId;
  final String sourceId;
  final int Function() readRevision;
  final bool Function() isAvailable;
  final CharacterAgentCommand? runCommand;
  CharacterAgentProvider({
    required this.character,
    required this.instanceId,
    required this.sourceId,
    required this.readRevision,
    required this.isAvailable,
    this.runCommand,
  });
  @override
  String get id => 'zyren.characters';
  @override
  String get version => '0.1.0';
  @override
  int get revision => readRevision();
  Registration register(AgentRegistry registry, AttachmentScope scope) =>
      scope.keep(registry.register(this));
  @override
  Map<String, Object?> get capabilities => {
    'timeUnits': 'seconds',
    'transformOwner': 'timeline-local-pose',
    'rootMotion': 'separate-locomotion-provider',
    'movement': 'host-controller-required',
    'commandsAvailable': runCommand != null,
  };

  /// Host can pass this enrichment callback to AgentViewportProvider.
  AgentObjectMetadata? describeObject(Object3D object) {
    if (!character.isAttached || !isAvailable()) return null;
    final targets = {
      for (final state in character.states)
        ...state.clip.tracks.map((t) => t.target),
    };
    for (Object3D? node = object; node != null; node = node.parent) {
      if (targets.contains(node)) {
        return AgentObjectMetadata(
          sourceId: sourceId,
          semanticType: 'character-part',
          owningPlugin: id,
          properties: {
            'characterState': character.currentState,
            'characterInstanceId': instanceId,
          },
          provenance: {
            'binding': 'host-character-source',
            'runtimeTargetId': node.id,
          },
          actions: [
            '$id/$instanceId/inspect',
            if (runCommand != null) '$id/$instanceId/playback',
          ],
        );
      }
    }
    return null;
  }

  static const _output = {'type': 'object', 'additionalProperties': true};
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'inspect',
      description:
          'Read animation states, clip clocks, targets and allowed transitions.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'offset': {'type': 'integer', 'minimum': 0},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 32},
        },
        'additionalProperties': false,
      },
      outputSchema: const {
        'type': 'object',
        'properties': {
          'sourceId': {'type': 'string'},
          'currentState': {'type': 'string'},
          'paused': {'type': 'boolean'},
          'states': {
            'type': 'array',
            'items': {'type': 'object'},
            'maxItems': 32,
          },
          'transitions': {
            'type': 'array',
            'items': {'type': 'object'},
            'maxItems': 128,
          },
          'totalStates': {'type': 'integer'},
          'totalOutgoingTransitions': {'type': 'integer'},
        },
        'required': [
          'sourceId',
          'currentState',
          'paused',
          'states',
          'transitions',
          'totalStates',
          'totalOutgoingTransitions',
        ],
        'additionalProperties': false,
      },
    ),
    AgentTool(
      name: 'playback',
      description:
          'Apply transition, pause or resume through the host command gateway.',
      readOnly: false,
      requiredScopes: const {'characters.playback'},
      inputSchema: const {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': ['transition', 'pause', 'resume'],
          },
          'state': {'type': 'string', 'maxLength': 128},
        },
        'required': ['action'],
        'additionalProperties': false,
      },
      outputSchema: _output,
    ),
  ];
  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    if (!character.isAttached || !isAvailable()) {
      return AgentResult(
        AgentStatus.stale,
        message: 'Character target is no longer attached.',
      );
    }
    if (tool == 'inspect') {
      final offset = arguments['offset'] as int? ?? 0,
          limit = arguments['limit'] as int? ?? 32;
      final weights = character.weights;
      return AgentResult(
        AgentStatus.ok,
        data: {
          'sourceId': sourceId,
          'currentState': character.currentState,
          'paused': character.isPaused,
          'totalStates': character.states.length,
          'totalOutgoingTransitions': character.transitions
              .where((t) => t.from == character.currentState)
              .length,
          'states': [
            for (final s in character.states.skip(offset).take(limit))
              {
                'id': s.id,
                'durationSeconds': s.clip.duration.inMicroseconds / 1e6,
                'positionSeconds':
                    character.positionOf(s.id).inMicroseconds / 1e6,
                'weight': weights[s.id],
                'loop': s.loop,
                'runtimeTargetIds': s.clip.tracks
                    .map((t) => t.target.id)
                    .take(128)
                    .toList(),
                'targetsTruncated': s.clip.tracks.length > 128,
              },
          ],
          'transitions': [
            for (final t
                in character.transitions
                    .where((t) => t.from == character.currentState)
                    .take(128))
              {
                'from': t.from,
                'to': t.to,
                'durationSeconds': t.duration.inMicroseconds / 1e6,
              },
          ],
        },
        revision: revision,
      );
    }
    if (tool != 'playback') return AgentResult(AgentStatus.unsupported);
    if (runCommand == null) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Host command gateway is unavailable.',
      );
    }
    final action = arguments['action'];
    if (action == 'transition' && arguments['state'] is! String) {
      return AgentResult(
        AgentStatus.invalid,
        message: 'Transition requires state.',
      );
    }
    if (action == 'transition' &&
        (character.isPaused ||
            arguments['state'] != character.currentState &&
                !character.transitions.any(
                  (t) =>
                      t.from == character.currentState &&
                      t.to == arguments['state'],
                ))) {
      return AgentResult(
        AgentStatus.invalid,
        message: 'Transition is not currently allowed.',
      );
    }
    final before = revision;
    runCommand!('character.$action', () {
      context.checkCancelled();
      if (revision != before || !isAvailable()) {
        throw StateError('Character changed before command.');
      }
      switch (action) {
        case 'transition':
          character.transitionTo(arguments['state'] as String);
        case 'pause':
          character.pause();
        case 'resume':
          character.resume();
      }
    });
    return AgentResult(
      AgentStatus.ok,
      data: {'state': character.currentState, 'paused': character.isPaused},
      revision: revision,
      affectedIds: [sourceId],
    );
  }
}
