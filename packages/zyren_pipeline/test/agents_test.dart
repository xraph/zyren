import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_pipeline/gltf_metadata.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_pipeline/agents.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

import 'runtime_test.dart' show fixture;

void main() {
  test(
    'shared viewport pick joins source provenance and rejects a removed target',
    () async {
      final (runtime, bundle) = await fixture();
      addTearDown(runtime.close);
      final job = runtime.start(
        bundleVersion: bundle.version,
        kind: PipelineJobKind.load,
      );
      await job.done;
      final instance = job.model!.instantiate();
      final scene = Scene()..add(instance);
      final camera = PerspectiveCamera(
        position: const Vec3(.25, .25, 5),
        target: const Vec3(.25, .25, 0),
      );
      final metadata = PipelineGltfMetadata(
        bundleVersion: bundle.version,
        sourceId: 'model',
        sourceRevision: 'drawing-r1',
        instance: instance,
        sourceIds: {0: 'part:triangle'},
      );
      final registry = AgentRegistry();
      addTearDown(registry.dispose);
      final viewport = AgentViewportProvider(
        sceneId: 'scene',
        documentId: 'document',
        instanceId: 'main-view',
        scene: scene,
        camera: () => camera,
        viewport: () => const ViewportMetrics(200, 100, devicePixelRatio: 2),
        metadata: (object) => pipelineGltfAgentMetadata(metadata, object),
      );
      registry.register(viewport);
      final picked = await registry.call(
        providerId: viewport.id,
        instanceId: viewport.instanceId,
        tool: 'pick',
        arguments: {'x': 100, 'y': 50},
      );
      expect(picked.status, AgentStatus.ok);
      final hit = (picked.data['hits'] as List).single as Map;
      final object = hit['object'] as Map;
      final imported = object['metadata'] as Map;
      expect(imported['sourceId'], 'part:triangle');
      expect(
        (imported['provenance'] as Map)['zyren.pipeline']['bundleVersion'],
        bundle.version,
      );
      expect(hit['renderedPixelVisibility'], 'unknown');
      expect(picked.data['devicePixelRatio'], 2);
      scene.remove(instance);
      final stale = await registry.call(
        providerId: viewport.id,
        instanceId: viewport.instanceId,
        tool: 'inspect_object',
        arguments: {'runtimeId': object['runtimeId']},
      );
      expect(stale.status, AgentStatus.stale);
    },
  );

  test(
    'registered discovery and read schemas expose bounded provenance',
    () async {
      final (runtime, bundle) = await fixture();
      final registry = AgentRegistry();
      final provider = PipelineAgentProvider(
        runtime: runtime,
        instanceId: 'assets',
      );
      final attachment = provider.attach(registry);
      addTearDown(() async {
        attachment.dispose();
        await runtime.close();
        registry.dispose();
      });
      final discovery = registry.discover();
      expect(
        (discovery['providers'] as List).single['providerId'],
        'zyren.pipeline',
      );
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'status',
        ),
        isEmpty,
      );
      for (final tool in ['bundles', 'jobs']) {
        expect(
          await AgentConformance.checkRead(
            registry: registry,
            provider: provider,
            tool: tool,
          ),
          isEmpty,
        );
      }
      final result = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'sources',
        arguments: {'version': bundle.version, 'limit': 1},
      );
      expect(result.status, AgentStatus.ok);
      expect((result.data['items'] as List).length, 1);
      expect(result.data['nextOffset'], 1);
      expect((result.data['items'] as List).first['sourceId'], 'model');
      expect(result.data.toString(), isNot(contains('memory:')));
      final invalid = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'sources',
        arguments: {'version': bundle.version, 'limit': 100},
      );
      expect(invalid.status, AgentStatus.invalid);
    },
  );

  test(
    'host grants, expected revisions and retry keys guard real commands',
    () async {
      final (runtime, bundle) = await fixture();
      final provider = PipelineAgentProvider(
        runtime: runtime,
        instanceId: 'assets',
      );
      final deniedRegistry = AgentRegistry();
      final deniedHandle = deniedRegistry.register(provider);
      final denied = await deniedRegistry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'start',
        arguments: {'version': bundle.version, 'kind': 'load'},
        expectedRevision: provider.revision,
        idempotencyKey: 'load-1',
      );
      expect(denied.status, AgentStatus.denied);
      expect(runtime.jobs, isEmpty);
      deniedHandle.dispose();
      deniedRegistry.dispose();
      final registry = AgentRegistry(
        grantedScopes: {
          'pipeline.load',
          'pipeline.jobs',
          'pipeline.cache.write',
        },
      );
      final handle = provider.attach(registry);
      addTearDown(() async {
        handle.dispose();
        await runtime.close();
        registry.dispose();
      });
      final before = provider.revision;
      Future<AgentResult> start() => registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'start',
        arguments: {'version': bundle.version, 'kind': 'load'},
        expectedRevision: before,
        idempotencyKey: 'load-1',
      );
      final started = await start();
      expect(started.status, AgentStatus.ok);
      final retry = await start();
      expect(retry.data['jobId'], started.data['jobId']);
      expect(runtime.jobs.length, 1);
      final job = runtime.jobs.single;
      await job.done;
      expect(job.state, PipelineJobState.succeeded);
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'jobs',
        ),
        isEmpty,
      );
      final stale = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'release',
        arguments: {'jobId': job.id},
        expectedRevision: before,
        idempotencyKey: 'stale',
      );
      expect(stale.status, AgentStatus.stale);
      final released = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'release',
        arguments: {'jobId': job.id},
        expectedRevision: provider.revision,
        idempotencyKey: 'release-1',
      );
      expect(released.status, AgentStatus.ok);
      expect(job.state, PipelineJobState.released);
      final invalidated = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'invalidate-source',
        arguments: {'sourceId': 'positions'},
        expectedRevision: provider.revision,
        idempotencyKey: 'invalidate-1',
      );
      expect(invalidated.status, AgentStatus.ok);
      expect(invalidated.data['removedCount'], 1);
      final missing = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'sources',
        arguments: {'version': bundle.version},
      );
      expect(missing.status, AgentStatus.stale);
    },
  );

  test(
    'cancel uses the ordinary load task and detach releases retained templates',
    () async {
      final (runtime, bundle) = await fixture();
      final registry = AgentRegistry(grantedScopes: {'pipeline.jobs'});
      final provider = PipelineAgentProvider(
        runtime: runtime,
        instanceId: 'assets',
      );
      final handle = provider.attach(registry);
      final job = runtime.start(
        bundleVersion: bundle.version,
        kind: PipelineJobKind.load,
      );
      final cancelled = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'cancel',
        arguments: {'jobId': job.id},
        expectedRevision: provider.revision,
        idempotencyKey: 'cancel',
      );
      expect(cancelled.status, AgentStatus.ok);
      await job.done;
      expect(job.state, PipelineJobState.cancelled);
      final loaded = runtime.start(
        bundleVersion: bundle.version,
        kind: PipelineJobKind.load,
      );
      await loaded.done;
      final model = loaded.model!;
      handle.dispose();
      await runtime.close();
      expect(model.isReleased, isTrue);
      expect(registry.discover()['providers'], isEmpty);
      final result = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'status',
      );
      expect(result.status, AgentStatus.unavailable);
      registry.dispose();
    },
  );
}
