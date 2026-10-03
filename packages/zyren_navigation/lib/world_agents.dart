/// Optional tools for generated navigation and dynamic obstacle snapshots.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_navigation.dart';

final class NavigationWorldAgentProvider extends AgentProvider {
  final NavigationWorld world;
  @override
  final String instanceId;
  final bool Function() isAvailable;
  final void Function(String, void Function())? runCommand;
  final BakedNavigationMesh Function()? rebuild;
  NavigationWorldAgentProvider({
    required this.world,
    required this.instanceId,
    required this.isAvailable,
    this.runCommand,
    this.rebuild,
  });
  @override
  String get id => 'zyren.navigation.world';
  @override
  String get version => '1.0.0';
  @override
  int get revision => world.revision;
  Registration register(AgentRegistry registry, AttachmentScope scope) =>
      scope.keep(registry.register(this));
  @override
  Map<String, Object?> get capabilities => {
    'units': 'metres',
    'up': 'Y',
    'surface': 'layered-heightfield',
    'radius': world.mesh.settings.radius,
    'height': world.mesh.settings.height,
    'dynamicObstacles': true,
    'bakeAvailable': rebuild != null && runCommand != null,
  };
  static const _vector = {
    'type': 'array',
    'items': {'type': 'number', 'minimum': -10000, 'maximum': 10000},
    'minItems': 3,
    'maxItems': 3,
  };
  static const _out = {'type': 'object', 'additionalProperties': true};
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'inspect',
      description: 'Read bake sources, agent dimensions and obstacle revision.',
      inputSchema: const {'type': 'object', 'additionalProperties': false},
      outputSchema: _out,
    ),
    AgentTool(
      name: 'find_path',
      description: 'Find a bounded current route on the generated surface.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'start': _vector,
          'goal': _vector,
          'maxVisited': {'type': 'integer', 'minimum': 1, 'maximum': 65536},
        },
        'required': ['start', 'goal'],
        'additionalProperties': false,
      },
      outputSchema: _out,
      maxResultBytes: 1048576,
    ),
    if (runCommand != null)
      AgentTool(
        name: 'set_obstacles',
        description:
            'Replace the obstacle snapshot through the host command gateway.',
        readOnly: false,
        requiredScopes: const {'navigation.edit'},
        inputSchema: const {
          'type': 'object',
          'properties': {
            'obstacles': {
              'type': 'array',
              'maxItems': 256,
              'items': {
                'type': 'object',
                'properties': {
                  'id': {'type': 'string', 'minLength': 1, 'maxLength': 128},
                  'min': _vector,
                  'max': _vector,
                },
                'required': ['id', 'min', 'max'],
                'additionalProperties': false,
              },
            },
          },
          'required': ['obstacles'],
          'additionalProperties': false,
        },
        outputSchema: _out,
      ),
    if (rebuild != null && runCommand != null)
      AgentTool(
        name: 'rebuild',
        description:
            'Bake the host-owned source snapshot and replace navigation atomically.',
        readOnly: false,
        requiredScopes: const {'navigation.edit'},
        inputSchema: const {'type': 'object', 'additionalProperties': false},
        outputSchema: _out,
      ),
  ];
  static Vec3 _vec(Object? value) {
    final v = value as List;
    return Vec3(
      (v[0] as num).toDouble(),
      (v[1] as num).toDouble(),
      (v[2] as num).toDouble(),
    );
  }

  Map<String, Object?> _inspect() => {
    'revision': revision,
    'cells': world.mesh.cells.length,
    'sources': world.mesh.sources,
    'settings': world.mesh.settings.json,
    'blockedCells': world.blockedCells.length,
    'obstacles': [
      for (final o in world.obstacles.values)
        {'id': o.id, 'min': o.min.storage, 'max': o.max.storage},
    ],
  };
  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    if (!isAvailable()) return AgentResult(AgentStatus.stale);
    if (tool == 'inspect') {
      return AgentResult(AgentStatus.ok, data: _inspect(), revision: revision);
    }
    if (tool == 'find_path') {
      final route = world.findPath(
        _vec(arguments['start']),
        _vec(arguments['goal']),
        maxVisited: arguments['maxVisited'] as int? ?? 4096,
        cancelled: () {
          context.checkCancelled();
          return false;
        },
      );
      return AgentResult(
        route.status == RouteStatus.found ? AgentStatus.ok : AgentStatus.empty,
        data: {
          'status': route.status.name,
          'revision': route.revision,
          'visited': route.visited,
          'points': [for (final p in route.points) p.storage],
          'cells': route.cells,
        },
        revision: revision,
      );
    }
    if (runCommand == null) return AgentResult(AgentStatus.unsupported);
    void Function() apply;
    if (tool == 'set_obstacles') {
      final obstacles = [
        for (final raw in arguments['obstacles'] as List)
          NavigationObstacle(
            (raw as Map)['id'] as String,
            min: _vec(raw['min']),
            max: _vec(raw['max']),
          ),
      ];
      apply = () => world.setObstacles(obstacles);
    } else if (tool == 'rebuild' && rebuild != null) {
      final mesh = rebuild!();
      context.checkCancelled();
      apply = () => world.replaceMesh(mesh);
    } else {
      return AgentResult(AgentStatus.unsupported);
    }
    runCommand!(tool, () {
      context.checkCancelled();
      if (!isAvailable()) throw StateError('Navigation was removed.');
      apply();
    });
    return AgentResult(AgentStatus.ok, data: _inspect(), revision: revision);
  }
}
