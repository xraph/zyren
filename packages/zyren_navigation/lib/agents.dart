/// Optional runtime agent queries. Register with the host's attachment scope.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_navigation.dart';

final class NavigationAgentProvider extends AgentProvider {
  final NavigationMesh mesh;
  @override
  final String instanceId;
  final String sourceId;
  final bool Function() isAvailable;
  NavigationAgentProvider({
    required this.mesh,
    required this.instanceId,
    required this.sourceId,
    required this.isAvailable,
  });
  @override
  String get id => 'zyren.navigation';
  @override
  String get version => '0.1.0';
  @override
  int get revision => 0; // An immutable mesh gets a new registration when replaced.
  Registration register(AgentRegistry registry, AttachmentScope scope) =>
      scope.keep(registry.register(this));
  @override
  Map<String, Object?> get capabilities => {
    'units': 'metres',
    'up': 'Y',
    'surface': 'horizontal-plane',
    'agent': 'point',
    'clearance': 'unsupported',
    'routeMethod': 'centroid-A-star-and-portal-midpoints',
    'renderedVisibility': 'unknown',
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
      name: 'find_path',
      description:
          'Find a point-agent route on this authored flat mesh. Coordinates are metres, Y up.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'start': _vector,
          'goal': _vector,
          'maxVisited': {
            'type': 'integer',
            'minimum': 1,
            'maximum': mesh.triangles.length,
          },
        },
        'required': ['start', 'goal'],
        'additionalProperties': false,
      },
      outputSchema: {
        'type': 'object',
        'properties': {
          'sourceId': {'type': 'string'},
          'status': {'type': 'string'},
          'triangles': {
            'type': 'array',
            'items': {'type': 'integer'},
            'maxItems': 1024,
          },
          'points': {'type': 'array', 'items': _vector, 'maxItems': 1025},
          'lengthMetres': {'type': 'number'},
          'visited': {'type': 'integer'},
        },
        'required': [
          'sourceId',
          'status',
          'triangles',
          'points',
          'lengthMetres',
          'visited',
        ],
        'additionalProperties': false,
      },
      maxResultBytes: 131072,
      examples: const [
        {
          'start': [0.1, 0, 0.1],
          'goal': [0.2, 0, 0.1],
        },
      ],
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
        message: 'Navigation source was removed or replaced.',
      );
    }
    if (tool != 'find_path') return AgentResult(AgentStatus.unsupported);
    Vec3 vector(String key) {
      final values = arguments[key] as List;
      return Vec3(
        (values[0] as num).toDouble(),
        (values[1] as num).toDouble(),
        (values[2] as num).toDouble(),
      );
    }

    final path = mesh.findPath(
      vector('start'),
      vector('goal'),
      maxVisited: arguments['maxVisited'] as int?,
    );
    return AgentResult(
      path.status == NavigationStatus.found
          ? AgentStatus.ok
          : AgentStatus.empty,
      data: {
        'sourceId': sourceId,
        'status': path.status.name,
        'triangles': path.triangles,
        'points': [for (final p in path.points) p.storage],
        'lengthMetres': path.length,
        'visited': path.visited,
      },
      revision: revision,
    );
  }
}
