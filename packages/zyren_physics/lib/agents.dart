/// Optional agent access to explicitly exposed physics bodies and their driver.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_physics.dart';

final class PhysicsAgentProvider extends AgentProvider {
  final PhysicsPlugin physics;
  final Map<String, PhysicsBody> bodies;
  @override
  final String instanceId;
  final int Function() readRevision;
  final bool Function() isAvailable;
  final void Function(String name, void Function() apply)? runCommand;
  PhysicsAgentProvider({
    required this.physics,
    required Map<String, PhysicsBody> bodies,
    required this.instanceId,
    required this.readRevision,
    required this.isAvailable,
    this.runCommand,
  }) : bodies = Map.unmodifiable(bodies) {
    if (bodies.length > 128 ||
        bodies.values.any((b) => !identical(b.world, physics.world))) {
      throw ArgumentError('Expose at most 128 bodies from this physics world.');
    }
  }
  @override
  String get id => 'zyren.physics';
  @override
  String get version => '0.1.0';
  @override
  int get revision => readRevision();
  Registration register(AgentRegistry registry, AttachmentScope scope) =>
      scope.keep(registry.register(this));
  @override
  Map<String, Object?> get capabilities => {
    'units': 'metres-seconds',
    'movement': 'kinematic-position-target-only',
    'stepping': 'host-owned',
    'commandsAvailable': runCommand != null,
    'rayQuery': 'not-exposed-query-events-are-stateful',
  };
  static const _vector = {
    'type': 'array',
    'items': {'type': 'number', 'minimum': -10000, 'maximum': 10000},
    'minItems': 3,
    'maxItems': 3,
  };
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'inspect',
      description:
          'Read simulation stepping state and explicitly exposed body poses.',
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
          'paused': {'type': 'boolean'},
          'fixedStepSeconds': {'type': 'number'},
          'droppedSeconds': {'type': 'number'},
          'totalBodies': {'type': 'integer'},
          'bodies': {
            'type': 'array',
            'items': {'type': 'object'},
            'maxItems': 32,
          },
        },
        'required': [
          'paused',
          'fixedStepSeconds',
          'droppedSeconds',
          'totalBodies',
          'bodies',
        ],
        'additionalProperties': false,
      },
    ),
    AgentTool(
      name: 'set_target',
      description:
          'Submit a position target to an exposed kinematic body. The host owns collision-safe movement and stepping.',
      readOnly: false,
      requiredScopes: const {'physics.move'},
      inputSchema: const {
        'type': 'object',
        'properties': {
          'bodyId': {'type': 'string', 'maxLength': 128},
          'position': _vector,
        },
        'required': ['bodyId', 'position'],
        'additionalProperties': false,
      },
      outputSchema: const {
        'type': 'object',
        'properties': {
          'bodyId': {'type': 'string'},
          'submitted': {'type': 'boolean'},
        },
        'required': ['bodyId', 'submitted'],
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
    if (physics.world.isClosed || !isAvailable()) {
      return AgentResult(
        AgentStatus.stale,
        message: 'Physics owner is unavailable.',
      );
    }
    if (tool == 'inspect') {
      final offset = arguments['offset'] as int? ?? 0,
          limit = arguments['limit'] as int? ?? 32;
      final result = <Map<String, Object?>>[];
      for (final entry in bodies.entries.skip(offset).take(limit)) {
        if (!entry.value.isAlive) {
          result.add({'sourceId': entry.key, 'status': 'stale'});
          continue;
        }
        final state = entry.value.state;
        result.add({
          'sourceId': entry.key,
          'runtimeBodyId': state.id,
          'kind': state.kind.name,
          'position': state.pose.position.storage,
          'velocity': state.velocity.storage,
          'sleeping': state.sleeping,
        });
      }
      return AgentResult(
        AgentStatus.ok,
        data: {
          'paused': physics.paused,
          'fixedStepSeconds': physics.world.fixedStep,
          'droppedSeconds': physics.droppedSeconds,
          'totalBodies': bodies.length,
          'bodies': result,
        },
        revision: revision,
      );
    }
    if (tool != 'set_target') return AgentResult(AgentStatus.unsupported);
    final body = bodies[arguments['bodyId']];
    if (body == null || !body.isAlive) {
      return AgentResult(AgentStatus.stale, message: 'Exposed body is stale.');
    }
    if (body.state.kind != BodyKind.kinematicPosition) {
      return AgentResult(
        AgentStatus.unsupported,
        message: 'Body does not accept position targets.',
      );
    }
    if (runCommand == null) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Host command gateway is unavailable.',
      );
    }
    final p = arguments['position'] as List;
    final pose = PhysicsPose(
      position: Vec3(
        (p[0] as num).toDouble(),
        (p[1] as num).toDouble(),
        (p[2] as num).toDouble(),
      ),
      rotation: body.state.pose.rotation,
    );
    final before = revision;
    runCommand!('physics.set_target', () {
      context.checkCancelled();
      if (revision != before || !isAvailable() || !body.isAlive) {
        throw StateError('Physics changed before command.');
      }
      body.setTarget(pose);
    });
    return AgentResult(
      AgentStatus.ok,
      data: {'bodyId': arguments['bodyId'], 'submitted': true},
      revision: revision,
      affectedIds: [arguments['bodyId'] as String],
    );
  }
}
