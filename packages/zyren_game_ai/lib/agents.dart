/// Optional developer tools. Production inference does not attach a registry.
library;

import 'dart:async';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'zyren_game_ai.dart';

enum GameAiControlKind { reset, selectModel }

final class GameAiControlCommand {
  final GameAiControlKind kind;
  final GameEntityHandle actor;
  final String? modelId;
  final int expectedRevision;
  const GameAiControlCommand(
    this.kind,
    this.actor,
    this.expectedRevision, {
    this.modelId,
  });
}

/// The host grants gameplay control separately from registry tool scopes.
final class GameAiPolicyHost {
  final PolicyGroup group;
  final Map<String, PolicyContract> models;
  final bool Function(GameAiControlCommand) permits;
  final int Function() currentRevision;
  GameAiPolicyHost({
    required this.group,
    required Map<String, PolicyContract> models,
    required this.permits,
    required this.currentRevision,
  }) : models = Map.unmodifiable(models) {
    if (models.isEmpty ||
        models.length > 8 ||
        models.keys.any((k) => k.isEmpty || k.length > 128)) {
      throw ArgumentError('Register one to eight bounded model names.');
    }
  }
  Future<AgentResult> execute(
    GameAiControlCommand command,
    AgentCallContext context,
  ) async {
    context.checkCancelled();
    if (command.expectedRevision != currentRevision()) {
      return AgentResult(AgentStatus.stale, message: 'Policy group changed.');
    }
    final initial = group.brainFor(command.actor)?.identity;
    if (initial == null ||
        !group.entities.isAlive(command.actor) ||
        group.isClosed) {
      return AgentResult(
        AgentStatus.stale,
        message: 'Actor generation is unavailable.',
      );
    }
    if (!permits(command)) {
      return AgentResult(
        AgentStatus.denied,
        message: 'Host gameplay control rejected the command.',
      );
    }
    if (command.kind == GameAiControlKind.reset) {
      group.reset(command.actor);
    } else {
      final contract = models[command.modelId];
      if (contract == null) {
        return AgentResult(
          AgentStatus.invalid,
          message: 'Model is not registered by this host.',
        );
      }
      MlModelLease? lease;
      try {
        lease = await group.ml.cache.acquire(contract.model);
        context.checkCancelled();
        if (currentRevision() != command.expectedRevision ||
            group.brainFor(command.actor)?.identity != initial ||
            !group.entities.isAlive(command.actor)) {
          return AgentResult(
            AgentStatus.stale,
            message: 'Actor or policy group changed during model loading.',
          );
        }
        if (!permits(command)) {
          return AgentResult(
            AgentStatus.denied,
            message: 'Host gameplay control changed during model loading.',
          );
        }
        await group.selectModel(command.actor, contract);
      } on MlLoadException catch (e) {
        return AgentResult(
          e.status == MlRunStatus.invalid
              ? AgentStatus.invalid
              : AgentStatus.unavailable,
          message: 'Registered native model could not load.',
        );
      } on MlCapacityException {
        return AgentResult(
          AgentStatus.unavailable,
          message: 'Native model capacity is exhausted.',
        );
      } finally {
        if (lease != null) await group.ml.cache.release(lease);
      }
    }
    return AgentResult(
      AgentStatus.ok,
      revision: currentRevision(),
      affectedIds: [command.actor.id],
      data: {'actor': group.inspect(command.actor)},
    );
  }
}

Map<String, Object?> _schema(
  Map<String, Object?> properties, {
  List<String> required = const [],
}) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};
const _actorFields = <String, Object?>{
  'actorId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
  'generation': {'type': 'integer', 'minimum': 1},
};
const _resultSchema = <String, Object?>{'type': 'object'};

final class GameAiAgentProvider extends AgentProvider {
  final GameAiPolicyHost host;
  @override
  final String instanceId;
  GameAiAgentProvider({required this.host, required this.instanceId});
  @override
  String get id => 'zyren_game_ai';
  @override
  String get version => '0.1.0';
  @override
  int get revision => host.currentRevision();
  @override
  Map<String, Object?> get capabilities => {
    'actorMessages':
        'separate host team channel, unavailable to developer tools',
    'maxActors': host.group.maxActors,
    'control': 'host validated, registered models only',
    'modelIds': host.models.keys.toList(),
  };
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'actors',
      description:
          'Inspect a bounded page of live policy actors and resource counters.',
      inputSchema: _schema({
        'offset': {'type': 'integer', 'minimum': 0, 'maximum': 64},
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 16},
      }),
      outputSchema: _resultSchema,
      requiredScopes: {'ai.read'},
    ),
    AgentTool(
      name: 'inspect',
      description:
          'Inspect permitted observations, goals, model pins and due ticks for an actor generation.',
      inputSchema: _schema(_actorFields, required: ['actorId', 'generation']),
      outputSchema: _resultSchema,
      requiredScopes: {'ai.read'},
    ),
    AgentTool(
      name: 'reset',
      description:
          'Ask the host to reset one live actor policy and invalidate pending results.',
      inputSchema: _schema(_actorFields, required: ['actorId', 'generation']),
      outputSchema: _resultSchema,
      readOnly: false,
      requiredScopes: {'ai.control'},
    ),
    AgentTool(
      name: 'select_model',
      description:
          'Ask the host to select a registered native model for one live actor generation.',
      inputSchema: _schema(
        {
          ..._actorFields,
          'modelId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
        },
        required: ['actorId', 'generation', 'modelId'],
      ),
      outputSchema: _resultSchema,
      readOnly: false,
      requiredScopes: {'ai.control'},
    ),
  ];
  @override
  FutureOr<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    final group = host.group;
    if (group.isClosed) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Policy group has closed.',
      );
    }
    if (tool == 'actors') {
      final offset = arguments['offset'] as int? ?? 0,
          limit = arguments['limit'] as int? ?? 16;
      final actors = group.actors.where(group.entities.isAlive).toList();
      final counters = group.ml.diagnostics;
      return AgentResult(
        actors.isEmpty ? AgentStatus.empty : AgentStatus.ok,
        revision: revision,
        data: {
          'actors': actors
              .skip(offset)
              .take(limit)
              .map((a) => {'id': a.id, 'generation': a.generation})
              .toList(),
          'nextOffset': offset + limit < actors.length ? offset + limit : null,
          'modelCount': group.modelCount,
          'stateBytes': group.stateBytes,
          'resources': {
            'queuedRequests': counters.queuedRequests,
            'queuedTensorBytes': counters.queuedTensorBytes,
            'inFlightBatches': counters.inFlightBatches,
            'residentModels': counters.residentModels,
            'modelWeightsBytes': counters.modelWeightsBytes,
            'nativeArenaBytes': counters.nativeArenaBytes,
          },
        },
      );
    }
    final actor = GameEntityHandle(
      arguments['actorId'] as String,
      arguments['generation'] as int,
    );
    if (!group.entities.isAlive(actor) || group.brainFor(actor) == null) {
      return AgentResult(
        AgentStatus.stale,
        message: 'Actor generation is unavailable.',
      );
    }
    if (tool == 'inspect') {
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        data: {'actor': group.inspect(actor)},
      );
    }
    if (tool == 'reset' || tool == 'select_model') {
      return host.execute(
        GameAiControlCommand(
          tool == 'reset'
              ? GameAiControlKind.reset
              : GameAiControlKind.selectModel,
          actor,
          context.expectedRevision!,
          modelId: arguments['modelId'] as String?,
        ),
        context,
      );
    }
    return AgentResult(AgentStatus.unsupported);
  }
}
