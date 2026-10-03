import 'package:zyren_agents/zyren_agents.dart';

/// Storage remains host-owned. A successful call must reflect the saved document.
class StudioPersistenceAgentProvider extends AgentProvider {
  @override
  final String instanceId;
  final int Function() readRevision;
  final bool Function() isAvailable, isSaved;
  final Future<void> Function() save;
  StudioPersistenceAgentProvider({
    required this.instanceId,
    required this.readRevision,
    required this.isAvailable,
    required this.isSaved,
    required this.save,
  });
  @override
  String get id => 'zyren.studio.persistence';
  @override
  String get version => '1.0.0';
  @override
  int get revision => readRevision();
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'save',
      description:
          'Save the active authored document, asset pins, materials, clips and review notes through the host store.',
      readOnly: false,
      requiredScopes: {'studio.save'},
      inputSchema: const {'type': 'object', 'additionalProperties': false},
      outputSchema: const {
        'type': 'object',
        'properties': {
          'saved': {'type': 'boolean'},
        },
        'required': ['saved'],
      },
    ),
  ];
  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    context.checkCancelled();
    if (tool != 'save') return AgentResult(AgentStatus.unsupported);
    if (!isAvailable()) return AgentResult(AgentStatus.unavailable);
    if (context.expectedRevision != revision) {
      return AgentResult(AgentStatus.stale);
    }
    await save();
    final saved = isSaved();
    return AgentResult(
      saved ? AgentStatus.ok : AgentStatus.failed,
      revision: revision,
      data: {'saved': saved},
      message: saved
          ? null
          : 'The active scene is not saved. Check Studio storage status.',
    );
  }
}
