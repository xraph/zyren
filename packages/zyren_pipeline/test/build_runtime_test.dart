import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_pipeline/build_agents.dart';
import '../example/triangle_source.dart';

void main() {
  Future<PipelineBuildResult> build() {
    final source = TriangleSource();
    return PipelineIncrementalBuilder(
      PipelineBuilder(resolver: source),
    ).build(sources: source.sources, transforms: [], entrySourceId: 'model');
  }

  test(
    'registered build commands enforce grants, retries, budgets and disposal',
    () async {
      var calls = 0;
      final gate = Completer<void>();
      final runtime = PipelineBuildRuntime(
        cache: PipelineCache(),
        maxJobs: 2,
        maxActiveJobs: 1,
        recipes: [
          PipelineBuildRecipe(
            id: 'fixture',
            version: '1',
            run: (token) async {
              calls++;
              await gate.future;
              token.throwIfCancelled();
              return build();
            },
          ),
        ],
      );
      final provider = PipelineBuildAgentProvider(
        runtime: runtime,
        instanceId: 'builder',
      );
      final denied = AgentRegistry();
      denied.register(provider);
      expect(
        (await denied.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'start',
          arguments: {'recipeId': 'fixture'},
          expectedRevision: provider.revision,
          idempotencyKey: 'denied',
        )).status,
        AgentStatus.denied,
      );
      denied.dispose();
      final registry = AgentRegistry(
        grantedScopes: {'pipeline.build', 'pipeline.jobs'},
      );
      final handle = provider.attach(registry);
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'recipes',
        ),
        isEmpty,
      );
      final revision = provider.revision;
      Future<AgentResult> start(String key) => registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'start',
        arguments: {'recipeId': 'fixture'},
        expectedRevision: revision,
        idempotencyKey: key,
      );
      final first = await start('first');
      expect(first.status, AgentStatus.ok);
      expect((await start('first')).data, first.data);
      expect((await start('old')).status, AgentStatus.stale);
      expect(calls, 1);
      expect(() => runtime.start('fixture'), throwsStateError);
      gate.complete();
      await runtime.jobs.single.done;
      expect(runtime.jobs.single.state, PipelineBuildState.succeeded);
      expect(runtime.jobs.single.cached, isTrue);
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'jobs',
        ),
        isEmpty,
      );
      expect(runtime.forget(runtime.jobs.single.id), isTrue);
      handle.dispose();
      await runtime.close();
      expect(runtime.jobs, isEmpty);
      registry.dispose();
    },
  );
  test('cancellation and retained output admission cannot publish', () async {
    final gate = Completer<void>();
    var published = 0;
    final runtime = PipelineBuildRuntime(
      cache: PipelineCache(),
      recipes: [
        PipelineBuildRecipe(
          id: 'wait',
          version: '1',
          run: (_) async {
            await gate.future;
            return build();
          },
        ),
      ],
      publish: (_, _) async {
        published++;
      },
    );
    final job = runtime.start('wait');
    runtime.cancel(job.id);
    gate.complete();
    await job.done;
    expect(job.state, PipelineBuildState.cancelled);
    expect(published, 0);
    await runtime.close();
    final small = PipelineBuildRuntime(
      cache: PipelineCache(),
      maxRetainedPayloadBytes: 1,
      recipes: [
        PipelineBuildRecipe(id: 'fixture', version: '1', run: (_) => build()),
      ],
      publish: (_, _) async {
        published++;
      },
    );
    final rejected = small.start('fixture');
    await rejected.done;
    expect(rejected.state, PipelineBuildState.failed);
    expect(published, 0);
    await small.close();
  });
  test('concurrent publishers reserve retained output budget', () async {
    final bytes = (await build()).bundle.byteLength;
    final entered = Completer<void>(), gate = Completer<void>();
    final runtime = PipelineBuildRuntime(
      cache: PipelineCache(),
      maxActiveJobs: 2,
      maxRetainedPayloadBytes: bytes,
      recipes: [
        PipelineBuildRecipe(id: 'fixture', version: '1', run: (_) => build()),
      ],
      publish: (_, _) async {
        entered.complete();
        await gate.future;
      },
    );
    final first = runtime.start('fixture');
    await entered.future;
    final second = runtime.start('fixture');
    await second.done;
    expect(second.state, PipelineBuildState.failed);
    gate.complete();
    await first.done;
    expect(first.state, PipelineBuildState.succeeded);
    await runtime.close();
  });

  test(
    'disk publication failure reports failure and memory cache misses remain explicit',
    () async {
      final runtime = PipelineBuildRuntime(
        cache: PipelineCache(),
        recipes: [
          PipelineBuildRecipe(id: 'fixture', version: '1', run: (_) => build()),
        ],
        publish: (_, _) async => throw StateError('Storage unavailable'),
      );
      final failed = runtime.start('fixture');
      await failed.done;
      expect(failed.state, PipelineBuildState.failed);
      expect(runtime.cache.length, 0);
      await runtime.close();
      final small = PipelineBuildRuntime(
        cache: PipelineCache(maxBytes: 1),
        recipes: [
          PipelineBuildRecipe(id: 'fixture', version: '1', run: (_) => build()),
        ],
      );
      final job = small.start('fixture');
      await job.done;
      expect(job.state, PipelineBuildState.succeeded);
      expect(job.cached, isFalse);
      await small.close();
    },
  );
}
