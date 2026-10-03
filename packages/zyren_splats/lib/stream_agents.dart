library;

import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'agents.dart';
import 'streaming.dart';

/// Appearance queries follow the same resident cut used by the scene renderer.
final class GaussianStreamAgentProvider extends AgentProvider {
  final GaussianStreamPlugin plugin;
  final AgentViewportProvider view;
  @override
  final String instanceId;
  GaussianStreamAgentProvider({
    required this.plugin,
    required this.view,
    required this.instanceId,
  });
  @override
  String get id => 'zyren.splats.stream';
  @override
  String get version => '0.1.0';
  @override
  int get revision =>
      view.revision +
      plugin.stream.revision +
      (plugin.renderer?.dataRevision ?? 0);
  @override
  Map<String, Object?> get capabilities => const {
    'queryCoverage': 'resident-LOD-Gaussian-appearance',
    'renderedPixelVisibility': 'unknown',
    'measurementSurface': false,
    'physicalGpuResidentBytes': null,
    'sorting': 'global-mean-depth-back-to-front',
    'mutations': false,
  };
  @override
  List<AgentTool> get tools => GaussianAgentProvider.supportedTools;

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
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    final renderer = plugin.renderer;
    if (plugin.stream.isClosed) return AgentResult(AgentStatus.stale);
    if (renderer == null || !renderer.enabled || plugin.hasPendingUpdate) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'The Gaussian scene has no current resident cut.',
        data: {'stream': plugin.stream.stats.toJson()},
      );
    }
    final result = GaussianAgentProvider.forScene(
      renderer,
      view: view,
      instanceId: instanceId,
    ).invoke(tool, arguments, context);
    return AgentResult(
      result.status,
      data: {
        ...result.data,
        'stream': plugin.stream.stats.toJson(),
        'coverage': capabilities,
      },
      message: result.message,
      revision: revision,
    );
  }
}
