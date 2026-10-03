import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'studio_assets.dart';

/// Reads the editor's actual disk-backed asset library, without a shadow cache.
final class StudioAssetsAgentProvider extends AgentProvider {
  final StudioScene scene;
  final StudioPipelineAssets assets;
  @override
  final String instanceId;
  StudioAssetsAgentProvider({
    required this.scene,
    required this.assets,
    required this.instanceId,
  });
  @override
  String get id => 'zyren.studio-assets';
  @override
  String get version => '0.1.0';
  @override
  int get revision => scene.revision;
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'status',
      description:
          'Inspect exact saved asset pins against the active disk-backed Pipeline library. Availability does not establish rendering or successful decoding.',
      inputSchema: const {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'offset': {'type': 'integer', 'minimum': 0, 'maximum': 32},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 8},
        },
      },
      outputSchema: const {'type': 'object'},
    ),
  ];
  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    if (tool != 'status') return AgentResult(AgentStatus.unsupported);
    context.checkCancelled();
    final expected = revision;
    final all = scene.document.assets;
    final results = <Map<String, Object?>>[];
    for (final asset
        in all
            .skip(arguments['offset'] as int? ?? 0)
            .take(arguments['limit'] as int? ?? 8)) {
      context.checkCancelled();
      String status;
      try {
        status = (await assets.inspect(asset)).name;
      } catch (_) {
        status = 'failed';
      }
      results.add({
        'id': asset.id,
        'status': status,
        'sourceBindings': asset.sourceNodes.length,
      });
    }
    context.checkCancelled();
    if (revision != expected) return AgentResult(AgentStatus.stale);
    return AgentResult(
      AgentStatus.ok,
      revision: revision,
      data: {
        'total': all.length,
        'assets': results,
        'storage': 'disk',
        'pixelVisibility': 'unknown',
      },
    );
  }
}
