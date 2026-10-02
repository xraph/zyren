/// Optional agent registry transport. Existing diagnostic tools stay read-only.
library;

import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_devtools.dart';

final class AgentDevtoolsBridge {
  final AgentRegistry registry;
  AgentDevtoolsBridge(this.registry);
  static const _string = {'type': 'string', 'minLength': 1, 'maxLength': 96};
  static const _callProperties = {
    'providerId': _string,
    'instanceId': _string,
    'tool': _string,
    'arguments': {'type': 'object'},
    'expectedRevision': {'type': 'integer', 'minimum': 0},
    'idempotencyKey': {'type': 'string', 'minLength': 1, 'maxLength': 128},
  };
  static const tools = <Map<String, Object?>>[
    {
      'name': 'agent_discover',
      'description':
          'Discover registered plugin instances, tools, schemas, limits and resources.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'offset': {'type': 'integer', 'minimum': 0},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 32},
        },
        'additionalProperties': false,
      },
      'annotations': {
        'readOnlyHint': true,
        'destructiveHint': false,
        'idempotentHint': true,
        'openWorldHint': false,
      },
    },
    {
      'name': 'agent_query',
      'description':
          'Call a discovered read-only plugin tool for a named instance. Mutations are rejected.',
      'inputSchema': {
        'type': 'object',
        'properties': _callProperties,
        'required': ['providerId', 'instanceId', 'tool'],
        'additionalProperties': false,
      },
      'annotations': {
        'readOnlyHint': true,
        'destructiveHint': false,
        'idempotentHint': true,
        'openWorldHint': false,
      },
    },
    {
      'name': 'agent_command',
      'description':
          'Call a discovered tool under host-granted scopes with revision and retry guards.',
      'inputSchema': {
        'type': 'object',
        'properties': _callProperties,
        'required': [
          'providerId',
          'instanceId',
          'tool',
          'expectedRevision',
          'idempotencyKey',
        ],
        'additionalProperties': false,
      },
      'annotations': {
        'readOnlyHint': false,
        'destructiveHint': true,
        'idempotentHint': false,
        'openWorldHint': false,
      },
    },
  ];
  static bool accepts(String name) => tools.any((tool) => tool['name'] == name);
  static bool isError(Map<String, Object?> response) {
    final result = response['agentResult'];
    return result is Map &&
        result['status'] != 'ok' &&
        result['status'] != 'empty';
  }

  Future<Map<String, Object?>> call(
    String name,
    Map<String, Object?> arguments,
  ) async {
    final descriptor = tools.where((tool) => tool['name'] == name).firstOrNull;
    if (descriptor == null) {
      throw const DiagnosticException(
        'unsupported',
        'Unknown agent bridge tool.',
      );
    }
    final error = AgentSchema.validate(
      descriptor['inputSchema'] as Map<String, Object?>,
      arguments,
    );
    if (error != null) throw DiagnosticException('invalidArguments', error);
    if (name == 'agent_discover') {
      return {
        'schemaVersion': SceneDiagnostics.schemaVersion,
        'agentDiscovery': registry.discover(
          offset: (arguments['offset'] as int?) ?? 0,
          limit: (arguments['limit'] as int?) ?? 16,
        ),
      };
    }
    final result = await registry.call(
      providerId: arguments['providerId'] as String,
      instanceId: arguments['instanceId'] as String,
      tool: arguments['tool'] as String,
      arguments: (arguments['arguments'] as Map<String, Object?>?) ?? const {},
      expectedRevision: arguments['expectedRevision'] as int?,
      idempotencyKey: arguments['idempotencyKey'] as String?,
      readOnlyOnly: name == 'agent_query',
    );
    return {
      'schemaVersion': SceneDiagnostics.schemaVersion,
      'agentResult': result.toJson(),
    };
  }
}

/// Optional existing inspector/diagnostics adapter. Inspector IDs remain local
/// to that inspector and must never be used as persistent source references.
final class DiagnosticsAgentProvider extends AgentProvider {
  final SceneDiagnostics diagnostics;
  final SceneDevtoolsPlugin inspector;
  @override
  final String instanceId;
  DiagnosticsAgentProvider({
    required this.diagnostics,
    required this.inspector,
    required this.instanceId,
  });
  @override
  String get id => 'zyren.devtools';
  @override
  String get version => SceneDiagnostics.packageVersion;
  @override
  int get revision => inspector.isAttached ? inspector.sceneRevision : -1;
  @override
  List<AgentTool> get tools => [
    for (final tool in SceneDiagnostics.tools)
      AgentTool(
        name: tool['name'] as String,
        description: tool['description'] as String,
        inputSchema: tool['inputSchema'] as Map<String, Object?>,
        outputSchema: const {'type': 'object'},
        maxResultBytes: 1048576,
      ),
  ];
  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    if (!inspector.isAttached) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Inspector is detached.',
      );
    }
    try {
      return AgentResult(
        AgentStatus.ok,
        data: diagnostics.call(tool, arguments),
        revision: revision,
      );
    } on DiagnosticException catch (error) {
      return AgentResult(
        error.code == 'objectNotFound'
            ? AgentStatus.stale
            : AgentStatus.invalid,
        message: error.message,
      );
    }
  }
}
