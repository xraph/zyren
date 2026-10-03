/// Scoped tools use the same local runner and registered project run requests.
library;

import 'package:zyren_agents/zyren_agents.dart';
import 'training.dart';

final class TrainingAgentProvider extends AgentProvider {
  final TrainingRunner runner;
  final Map<String, TrainingRunRequest> requests;
  final int Function() currentRevision;
  final bool Function(String tool) permits;
  @override
  final String instanceId;
  TrainingAgentProvider({
    required this.runner,
    required Map<String, TrainingRunRequest> requests,
    required this.currentRevision,
    required this.permits,
    required this.instanceId,
  }) : requests = Map.unmodifiable(requests) {
    if (requests.length > 16) {
      throw ArgumentError('Too many registered training profiles.');
    }
  }
  @override
  String get id => 'zyren.training';
  @override
  String get version => '0.1.0';
  @override
  int get revision => currentRevision() + runner.revision;
  @override
  Map<String, Object?> get capabilities => {
    'local': true,
    'profiles': requests.keys.toList(),
    'policyQuality': null,
  };
  @override
  List<AgentTool> get tools => [
    for (final name in ['inspect', 'start', 'stop'])
      AgentTool(
        name: name,
        description: '$name local training through the project runner.',
        readOnly: name == 'inspect',
        requiredScopes: {'training.$name'},
        inputSchema: {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            if (name == 'start') 'profile': {'type': 'string'},
            if (name == 'stop')
              'run': {'type': 'integer', 'minimum': 0, 'maximum': 63},
          },
          if (name != 'inspect')
            'required': [name == 'start' ? 'profile' : 'run'],
        },
        outputSchema: const {'type': 'object'},
      ),
  ];
  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    context.checkCancelled();
    if (!permits(tool)) return AgentResult(AgentStatus.denied);
    if (tool != 'inspect' && context.expectedRevision != revision) {
      return AgentResult(AgentStatus.stale, revision: revision);
    }
    try {
      if (tool == 'start') {
        final request = requests[arguments['profile']];
        if (request == null) {
          return AgentResult(
            AgentStatus.invalid,
            message: 'Unknown registered training profile.',
          );
        }
        final pinnedRevision = currentRevision();
        await runner.start(
          request,
          authorize: () =>
              !context.cancellation.isCancelled &&
              currentRevision() == pinnedRevision &&
              permits(tool),
        );
      } else if (tool == 'stop') {
        final index = arguments['run'] as int;
        if (index >= runner.runs.length) {
          return AgentResult(AgentStatus.invalid);
        }
        await runner.runs[index].stop();
      } else if (tool != 'inspect') {
        return AgentResult(AgentStatus.unsupported);
      }
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        data: {
          'runs': [
            for (final run in runner.runs)
              {
                'state': run.state.name,
                'steps': run.steps,
                'checkpointHash': run.checkpointHash,
                'error': run.error,
                'exitCode': run.exitCode,
              },
          ],
        },
      );
    } catch (error) {
      return AgentResult(
        AgentStatus.failed,
        message: '$error',
        revision: revision,
      );
    }
  }
}
