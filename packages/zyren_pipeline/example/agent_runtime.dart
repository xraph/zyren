import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_pipeline/agents.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

import 'triangle_source.dart';

Future<void> main() async {
  final source = TriangleSource();
  final bundle = await PipelineBuilder(
    resolver: source,
  ).build(entrySourceId: 'model', sources: source.sources);
  final runtime = PipelineRuntime(cache: PipelineCache()..put(bundle));
  final registry = AgentRegistry(grantedScopes: {'pipeline.load'});
  final provider = PipelineAgentProvider(
    runtime: runtime,
    instanceId: 'demo-assets',
  );
  final attachment = provider.attach(registry);
  try {
    final discovery = registry.discover();
    print(
      '${(discovery['providers'] as List).length} registered pipeline provider',
    );
    final started = await registry.call(
      providerId: provider.id,
      instanceId: provider.instanceId,
      tool: 'start',
      arguments: {'version': bundle.version, 'kind': 'validate'},
      expectedRevision: provider.revision,
      idempotencyKey: 'validate-demo-v1',
    );
    if (!started.isSuccess) {
      throw StateError('Validation job rejected: ${started.status.name}');
    }
    await runtime.job(started.data['jobId'] as String)!.done;
    final jobs = await registry.call(
      providerId: provider.id,
      instanceId: provider.instanceId,
      tool: 'jobs',
    );
    print(jobs.toJson());
  } finally {
    attachment.dispose();
    await runtime.close();
    registry.dispose();
  }
}
