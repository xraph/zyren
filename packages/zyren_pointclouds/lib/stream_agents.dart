library;

import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'agents.dart';
import 'streaming.dart';

/// Shared-runtime inspection and host-granted filtering for the visible LOD cut.
final class PointCloudStreamAgentProvider extends AgentProvider {
  final PointCloudStreamPlugin plugin;
  final AgentViewportProvider view;
  @override
  final String instanceId;
  final _undo = <(PointCloudFilter, PointCloudFilter)>[];
  int _commands = 0;
  PointCloudStreamAgentProvider({
    required this.plugin,
    required this.view,
    required this.instanceId,
  });
  Registration register(AgentRegistry registry) {
    final registration = registry.register(this);
    try {
      plugin.onClose(registration.dispose);
    } catch (_) {
      registration.dispose();
      rethrow;
    }
    return registration;
  }

  @override
  String get id => 'zyren.pointclouds.stream';
  @override
  String get version => '0.1.0';
  @override
  int get revision =>
      view.revision +
      plugin.stream.revision +
      plugin.filterRevision +
      _commands;
  @override
  Map<String, Object?> get capabilities => const {
    'sourceIdentity': 'source-uri/version/record-ordinal',
    'queryCoverage': 'filtered-resident-LOD-samples',
    'renderedPixelVisibility': 'unknown',
    'physicalGpuResidentBytes': null,
    'filterUndo': true,
    'mutations': 'host-scoped',
  };
  @override
  late final tools = <AgentTool>[
    AgentTool(
      name: 'inspect',
      description: 'Inspect point loading, budgets, failures and selected LOD.',
      inputSchema: _schema({}),
      outputSchema: _output,
    ),
    AgentTool(
      name: 'pick',
      description: 'Query original samples in the visible filtered LOD cut.',
      inputSchema: _schema(
        {
          'x': {'type': 'number'},
          'y': {'type': 'number'},
          'radius': {'type': 'number', 'exclusiveMinimum': 0},
          'expectedCameraRevision': {'type': 'integer', 'minimum': 0},
          'expectedFrameId': {'type': 'string', 'maxLength': 128},
        },
        required: ['x', 'y', 'radius'],
      ),
      outputSchema: _output,
    ),
    AgentTool(
      name: 'filter',
      description:
          'Set source classification and intensity filters through the point scene API.',
      readOnly: false,
      requiredScopes: {'pointclouds.filter'},
      inputSchema: _schema({
        'classifications': {
          'type': 'array',
          'maxItems': 256,
          'items': {'type': 'integer', 'minimum': 0, 'maximum': 255},
        },
        'minIntensity': {'type': 'number'},
        'maxIntensity': {'type': 'number'},
        'includeWithheld': {'type': 'boolean'},
      }),
      outputSchema: _output,
    ),
    AgentTool(
      name: 'undoFilter',
      description:
          'Undo the latest filter if it has not been replaced by the host.',
      readOnly: false,
      requiredScopes: {'pointclouds.filter'},
      inputSchema: _schema({}),
      outputSchema: _output,
    ),
    AgentTool(
      name: 'retry',
      description:
          'Retry failed point chunks through the normal stream loader.',
      readOnly: false,
      requiredScopes: {'pointclouds.retry'},
      inputSchema: _schema({}),
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
    if (plugin.stream.isClosed) {
      return AgentResult(AgentStatus.stale, message: 'Point stream is closed.');
    }
    final viewport = Map<String, Object?>.from(
      view.invoke('context', const {}, context).data,
    )..remove('coverage');
    final output = <String, Object?>{
      'context': viewport,
      'runtimeId': plugin.object.id,
      'coverage': capabilities,
      'stream': plugin.stream.stats.toJson(),
      'failures': Map.fromEntries(plugin.stream.failures.entries.take(32)),
      'failuresTruncated': plugin.stream.failures.length > 32,
      'selectedChunks': plugin.stream.selectedIds.take(128).toList(),
      'selectedChunksTruncated': plugin.stream.selectedIds.length > 128,
      'filterPending': plugin.hasPendingUpdate,
      'availableActions': ['filter', 'undoFilter', 'retry'],
    };
    if (tool == 'inspect') {
      return AgentResult(AgentStatus.ok, data: output, revision: revision);
    }
    if (tool == 'filter') {
      final next = PointCloudFilter(
        classifications: (arguments['classifications'] as List?)
            ?.cast<int>()
            .toSet(),
        minIntensity: (arguments['minIntensity'] as num?)?.toDouble(),
        maxIntensity: (arguments['maxIntensity'] as num?)?.toDouble(),
        includeWithheld: arguments['includeWithheld'] as bool? ?? true,
      );
      context.checkCancelled();
      _undo.add((plugin.filter, next));
      if (_undo.length > 32) _undo.removeAt(0);
      plugin.filter = next;
      _commands++;
    } else if (tool == 'undoFilter') {
      if (_undo.isEmpty) {
        return AgentResult(AgentStatus.empty, data: output, revision: revision);
      }
      final previous = _undo.last;
      if (!identical(plugin.filter, previous.$2)) {
        return AgentResult(
          AgentStatus.stale,
          message: 'The host changed the point filter.',
        );
      }
      context.checkCancelled();
      _undo.removeLast();
      plugin.filter = previous.$1;
      _commands++;
    } else if (tool == 'retry') {
      context.checkCancelled();
      plugin.stream.retryFailed();
      _commands++;
    } else if (tool == 'pick') {
      if (plugin.hasPendingUpdate) {
        return AgentResult(
          AgentStatus.unavailable,
          message: 'Await the next point scene update.',
        );
      }
      final hits = <Map<String, Object?>>[];
      for (final cloud in plugin.visibleClouds.values) {
        context.checkCancelled();
        final result = PointCloudAgentProvider(
          cloud: cloud,
          view: view,
          instanceId: instanceId,
        ).invoke('pick', arguments, context);
        if (!result.isSuccess) return result;
        hits.addAll(
          (result.data['hits'] as List).map(
            (v) => (v as Map).cast<String, Object?>(),
          ),
        );
      }
      hits.sort(
        (a, b) => (a['distance'] as num).compareTo(b['distance'] as num),
      );
      output['hits'] = hits.take(1).toList();
      return AgentResult(
        hits.isEmpty ? AgentStatus.empty : AgentStatus.ok,
        data: output,
        revision: revision,
      );
    } else {
      return AgentResult(AgentStatus.unsupported);
    }
    output['filterPending'] = plugin.hasPendingUpdate;
    output['undoDepth'] = _undo.length;
    return AgentResult(
      AgentStatus.ok,
      data: output,
      revision: revision,
      affectedIds: [plugin.object.id.toString()],
    );
  }
}

Map<String, Object?> _schema(
  Map<String, Object?> properties, {
  List<String> required = const [],
}) => {
  'type': 'object',
  'properties': properties,
  'additionalProperties': false,
  if (required.isNotEmpty) 'required': required,
};
const _output = <String, Object?>{
  'type': 'object',
  'additionalProperties': true,
};
