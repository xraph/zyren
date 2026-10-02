/// Optional cached particle inspection and host-authorized playback.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_particles.dart';

final class ParticleAgentProvider extends AgentProvider {
  final ParticleController controller;
  @override
  final String instanceId;
  final int Function() readRevision;
  final bool Function() isAvailable;
  final Future<void> Function(String name, Future<void> Function() apply)?
  runCommand;
  ParticleAgentProvider({
    required this.controller,
    required this.instanceId,
    required this.readRevision,
    required this.isAvailable,
    this.runCommand,
  });
  @override
  String get id => 'zyren.particles';
  @override
  String get version => '0.1.0';
  @override
  int get revision => readRevision();
  Registration register(AgentRegistry registry, AttachmentScope scope) =>
      scope.keep(registry.register(this));
  @override
  Map<String, Object?> get capabilities => {
    'inspection': 'cached-controller-measurements',
    'gpuReadback': false,
    'renderedVisibility': 'unknown',
    'commandsAvailable': runCommand != null,
  };
  @override
  List<AgentTool> get tools => toolDefinitions;

  static final List<AgentTool> toolDefinitions = List.unmodifiable([
    AgentTool(
      name: 'inspect',
      description:
          'Read emitter playback and cached measurements without GPU readback. Unknown live counts remain null.',
      inputSchema: const {'type': 'object', 'additionalProperties': false},
      outputSchema: const {
        'type': 'object',
        'properties': {
          'emitters': {
            'type': 'array',
            'items': {'type': 'object'},
            'maxItems': 32,
          },
        },
        'required': ['emitters'],
        'additionalProperties': false,
      },
    ),
    AgentTool(
      name: 'playback',
      description:
          'Pause or resume an existing emitter through the host command gateway.',
      readOnly: false,
      requiredScopes: const {'particles.playback'},
      inputSchema: const {
        'type': 'object',
        'properties': {
          'emitter': {'type': 'string', 'maxLength': 128},
          'action': {
            'type': 'string',
            'enum': ['pause', 'resume'],
          },
        },
        'required': ['emitter', 'action'],
        'additionalProperties': false,
      },
      outputSchema: const {
        'type': 'object',
        'properties': {
          'emitter': {'type': 'string'},
          'playback': {'type': 'string'},
        },
        'required': ['emitter', 'playback'],
        'additionalProperties': false,
      },
    ),
  ]);
  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    context.checkCancelled();
    if (controller.isClosed || !isAvailable()) {
      return AgentResult(
        AgentStatus.stale,
        message: 'Particle controller is unavailable.',
      );
    }
    if (tool == 'inspect') {
      return AgentResult(
        AgentStatus.ok,
        data: {
          'emitters': [
            for (final name in controller.names)
              {
                'name': name,
                'playback': controller.playback(name).name,
                'pendingSeconds': controller.pendingSeconds(name),
                'simulationTicks': controller
                    .measurements(name)
                    .simulationTicks,
                'liveParticles': controller.measurements(name).liveParticles,
              },
          ],
        },
        revision: revision,
      );
    }
    if (tool != 'playback') return AgentResult(AgentStatus.unsupported);
    final name = arguments['emitter'] as String;
    if (!controller.names.contains(name)) {
      return AgentResult(
        AgentStatus.stale,
        message: 'Emitter no longer exists.',
      );
    }
    if (runCommand == null) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Host command gateway is unavailable.',
      );
    }
    final before = revision;
    await runCommand!('particles.${arguments['action']}', () async {
      context.checkCancelled();
      if (revision != before || controller.isClosed || !isAvailable()) {
        throw StateError('Particles changed before command.');
      }
      if (arguments['action'] == 'pause') {
        await controller.pause(name);
      } else {
        await controller.resume(name);
      }
    });
    return AgentResult(
      AgentStatus.ok,
      data: {'emitter': name, 'playback': controller.playback(name).name},
      revision: revision,
      affectedIds: [name],
    );
  }
}
