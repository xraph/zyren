import 'dart:async';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_pipeline.dart';

/// Shared-registry access to host-registered recipes. No shell, URI or payload
/// arguments cross the agent boundary. Detachment cancels and drains owned jobs.
final class PipelineBuildAgentProvider extends AgentProvider {
  final PipelineBuildRuntime runtime;
  @override
  final String instanceId;
  PipelineBuildAgentProvider({required this.runtime, required this.instanceId});
  @override
  String get id => 'zyren.pipeline-build';
  @override
  String get version => '0.1.0';
  @override
  int get revision => runtime.revision;
  @override
  Map<String, Object?> get capabilities => {
    'maxJobs': runtime.maxJobs,
    'maxRetainedPayloadBytes': runtime.maxRetainedPayloadBytes,
    'maxActiveJobs': runtime.maxActiveJobs,
    'durablePublisher': runtime.publish != null,
    'recipes': 'host-registered',
    'pixels': 'unknown',
  };
  Registration attach(AgentRegistry registry) {
    final handle = registry.register(this);
    return Registration(() {
      handle.dispose();
      unawaited(runtime.close());
    });
  }

  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'recipes',
      description: 'List host-approved pinned build recipes.',
      inputSchema: _page,
      outputSchema: _items(_object({'id': _id, 'version': _id})),
    ),
    AgentTool(
      name: 'jobs',
      description:
          'Inspect bounded preparation/build jobs and bundle receipts.',
      inputSchema: _page,
      outputSchema: _items(_jobSchema),
    ),
    AgentTool(
      name: 'start',
      description:
          'Build a host-approved recipe using ordinary pipeline commands.',
      inputSchema: _object({'recipeId': _id}, required: ['recipeId']),
      outputSchema: _jobSchema,
      readOnly: false,
      requiredScopes: {'pipeline.build'},
    ),
    for (final action in ['cancel', 'forget'])
      AgentTool(
        name: action,
        description: '$action a retained build job.',
        inputSchema: _object({'jobId': _id}, required: ['jobId']),
        outputSchema: _object({
          'changed': {'type': 'boolean'},
        }),
        readOnly: false,
        requiredScopes: {'pipeline.jobs'},
      ),
  ];
  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    if (runtime.isClosed) return AgentResult(AgentStatus.unavailable);
    Map<String, Object?> page(List<Map<String, Object?>> values) => {
      'items': values
          .skip(arguments['offset'] as int? ?? 0)
          .take(arguments['limit'] as int? ?? 16)
          .toList(),
      'total': values.length,
    };
    Map<String, Object?> data;
    switch (tool) {
      case 'recipes':
        data = page([
          for (final r in runtime.recipes) {'id': r.id, 'version': r.version},
        ]);
      case 'jobs':
        data = page(runtime.jobs.map(_job).toList());
      case 'start':
        try {
          data = _job(runtime.start(arguments['recipeId'] as String));
        } on ArgumentError {
          return AgentResult(AgentStatus.stale);
        } on StateError {
          return AgentResult(AgentStatus.unavailable);
        }
      case 'cancel':
        data = {'changed': runtime.cancel(arguments['jobId'] as String)};
      case 'forget':
        data = {'changed': runtime.forget(arguments['jobId'] as String)};
      default:
        return AgentResult(AgentStatus.unsupported);
    }
    return AgentResult(
      data['items'] is List && (data['items'] as List).isEmpty
          ? AgentStatus.empty
          : AgentStatus.ok,
      data: data,
      revision: revision,
    );
  }
}

Map<String, Object?> _job(PipelineBuildJob j) => {
  'jobId': j.id,
  'recipeId': j.recipeId,
  'recipeVersion': j.recipeVersion,
  'state': j.state.name,
  'cached': j.cached,
  if (j.errorCode != null) 'errorCode': j.errorCode,
  if (j.result != null) ...{
    'bundleVersion': j.result!.bundle.version,
    'built': j.result!.built.length,
    'reused': j.result!.reused.length,
    'payloadBytes': j.result!.bundle.byteLength,
  },
};
const _id = {'type': 'string', 'minLength': 1, 'maxLength': 256};
Map<String, Object?> _object(
  Map<String, Object?> properties, {
  List<String> required = const [],
}) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};
final _page = _object({
  'offset': {'type': 'integer', 'minimum': 0, 'maximum': 10000},
  'limit': {'type': 'integer', 'minimum': 1, 'maximum': 16},
});
Map<String, Object?> _items(Map<String, Object?> item) => _object({
  'items': {'type': 'array', 'maxItems': 16, 'items': item},
  'total': {'type': 'integer', 'minimum': 0},
});
final _jobSchema = _object({
  'cached': {'type': 'boolean'},
  'jobId': _id,
  'recipeId': _id,
  'recipeVersion': _id,
  'errorCode': _id,
  'state': {
    'type': 'string',
    'enum': PipelineBuildState.values.map((s) => s.name).toList(),
  },
  'bundleVersion': {'type': 'string', 'minLength': 64, 'maxLength': 64},
  for (final field in ['built', 'reused', 'payloadBytes'])
    field: {'type': 'integer', 'minimum': 0},
});
