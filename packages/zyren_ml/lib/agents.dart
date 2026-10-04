/// Optional scoped tooling adapter; the inference entry has no scene imports.
library;

import 'dart:async';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_ml.dart';

typedef MlHostCommand =
    FutureOr<AgentResult> Function(String modelId, AgentCallContext context);

final class MlAgentProvider extends AgentProvider {
  final MlScheduler scheduler;
  final Map<String, MlModelManifest> models;
  final int Function() currentRevision;
  final MlHostCommand? selectModel;
  @override
  final String instanceId;
  MlAgentProvider({
    required this.scheduler,
    required Map<String, MlModelManifest> models,
    required this.currentRevision,
    required this.instanceId,
    this.selectModel,
  }) : models = Map.unmodifiable(models) {
    if (models.length > 8 ||
        models.keys.any((k) => k.isEmpty || k.length > 128)) {
      throw ArgumentError(
        'Model discovery is bounded to eight registered models.',
      );
    }
  }
  @override
  String get id => 'zyren_ml';
  @override
  String get version => '0.1.0';
  @override
  int get revision => currentRevision();
  @override
  Map<String, Object?> get capabilities => {
    'runtime': 'local native ONNX Runtime',
    'files': 'host-owned model resolver only',
    'arenaBytes': 'unknown unless runtime reports it',
    'control': selectModel != null,
  };
  Map<String, Object?> _input(
    Map<String, Object?> properties, {
    List<String> required = const [],
  }) => {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  };
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'inspect',
      description:
          'Inspect native model pins and admission counters without running inference.',
      inputSchema: _input({}),
      outputSchema: {'type': 'object'},
      requiredScopes: {'ml.read'},
    ),
    if (selectModel != null)
      AgentTool(
        name: 'select_model',
        description:
            'Ask the host to select a registered native model through its command validation.',
        inputSchema: _input(
          {
            'modelId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
          },
          required: ['modelId'],
        ),
        outputSchema: {'type': 'object'},
        requiredScopes: {'ml.control'},
        readOnly: false,
      ),
  ];
  @override
  FutureOr<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    if (tool == 'inspect') {
      final d = scheduler.diagnostics;
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        data: {
          'models': [
            for (final entry in models.entries)
              {
                'id': entry.key,
                'sha256': entry.value.sha256,
                'opset': entry.value.opset,
                'providers': entry.value.providers,
                'runtimeVersion': entry.value.runtimeVersion,
              },
          ],
          'resources': {
            'queuedRequests': d.queuedRequests,
            'queuedTensorBytes': d.queuedTensorBytes,
            'inFlightBatches': d.inFlightBatches,
            'inFlightTensorBytes': d.inFlightTensorBytes,
            'residentModels': d.residentModels,
            'modelWeightsBytes': d.modelWeightsBytes,
            'leaseReferences': d.leaseReferences,
            'inFlightReferences': d.inFlightReferences,
            'nativeArenaBytes': d.nativeArenaBytes,
          },
        },
      );
    }
    if (tool == 'select_model' && selectModel != null) {
      final modelId = arguments['modelId'] as String;
      if (!models.containsKey(modelId)) {
        return AgentResult(
          AgentStatus.invalid,
          message: 'Model is not registered by this host.',
        );
      }
      return selectModel!(modelId, context);
    }
    return AgentResult(AgentStatus.unsupported);
  }
}
