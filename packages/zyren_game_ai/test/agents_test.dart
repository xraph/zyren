import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_ai/agents.dart';
import 'package:zyren_ml/agents.dart';
import 'package:zyren_ml/zyren_ml.dart';
import '../../zyren_ml/test/support/delayed_worker.dart'
    show DelayedWorker, fakeManifest;
import 'policy_test.dart' show PolicyFixture;

void main() {
  test(
    'diagnostics report the dispatched deadline after a newer observation arrives',
    () async {
      final f = PolicyFixture(), worker = DelayedWorker();
      var tick = 1;
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: worker,
          resolver: (_) async => Uint8List.fromList([7]),
        ),
        currentTick: () => tick,
      );
      final group = PolicyGroup(episodeId: 'ep', entities: f.entities, ml: ml);
      final actor = f.entities.spawn('actor'), model = fakeManifest();
      final brain = group.join(
        BrainIdentity(episodeId: 'ep', entity: actor, modelHash: model.sha256),
        f.contract(model, ActionDecoder.character()),
      );
      addTearDown(() async {
        await group.close();
        await ml.close();
      });
      brain.observe(f.frame(brain.identity, tick));
      final deadline = DateTime.now().toUtc().add(const Duration(minutes: 1));
      final pending = brain.request(f.context(brain, tick), deadline: deadline);
      final flush = ml.flush();
      await worker.started.future;
      tick = 2;
      brain.observe(f.frame(brain.identity, tick));
      final snapshot = group.inspect(actor);
      expect(snapshot['applicationTick'], 3);
      expect(snapshot['deadlineTick'], 3);
      expect(snapshot['request'], containsPair('observationTick', 1));
      expect(
        snapshot['request'],
        containsPair('deadline', deadline.toIso8601String()),
      );
      worker.finish();
      await pending;
      await flush;
      expect(brain.activeRequest, isNull);
      expect(group.inspect(actor)['applicationTick'], 3);
      brain.invalidatePending();
      expect(group.inspect(actor)['applicationTick'], isNull);
    },
  );
  test(
    'scoped tools stay passive, require host control and reject old revisions',
    () async {
      final f = PolicyFixture(), worker = DelayedWorker();
      final ml = MlScheduler(
        cache: MlModelCache(
          resolver: (_) async => Uint8List.fromList([7]),
          worker: worker,
        ),
        currentTick: () => 1,
      );
      final group = PolicyGroup(episodeId: 'ep', entities: f.entities, ml: ml);
      final actor = f.entities.spawn('actor');
      final model = fakeManifest();
      final contract = f.contract(model, ActionDecoder.character());
      final brain = group.join(
        BrainIdentity(episodeId: 'ep', entity: actor, modelHash: model.sha256),
        contract,
      );
      final peer = f.entities.spawn('peer');
      group.join(
        BrainIdentity(episodeId: 'ep', entity: peer, modelHash: model.sha256),
        contract,
      );
      expect(group.modelCount, 1);
      expect(identical(group.stateFor(actor), group.stateFor(peer)), false);
      final foreign = f.entities.spawn('foreign');
      expect(
        () => group.join(
          BrainIdentity(
            episodeId: 'other',
            entity: foreign,
            modelHash: model.sha256,
          ),
          contract,
        ),
        throwsArgumentError,
      );
      expect(
        () => group.join(
          BrainIdentity(
            episodeId: 'ep',
            entity: foreign,
            modelHash: model.sha256,
          ),
          f.contract(
            fakeManifest(id: 'different-manifest'),
            ActionDecoder.character(),
          ),
        ),
        throwsArgumentError,
      );
      brain.observe(f.frame(brain.identity, 1));
      group.record(f.context(brain, 1));
      var permits = false;
      final host = GameAiPolicyHost(
        group: group,
        models: {'probe': contract},
        permits: (_) => permits,
        currentRevision: () => group.revision,
      );
      final registry = AgentRegistry(
        grantedScopes: {'ai.read', 'ai.control', 'ml.read'},
      );
      final provider = GameAiAgentProvider(host: host, instanceId: 'episode');
      final registration = registry.register(provider);
      registry.register(
        MlAgentProvider(
          scheduler: ml,
          models: {'probe': model},
          currentRevision: () => group.revision,
          instanceId: 'worker',
        ),
      );
      addTearDown(() async {
        registration.dispose();
        registry.dispose();
        await group.close();
        await ml.close();
      });
      Future<AgentResult> call(
        String tool, {
        int? revision,
        AgentCancellation? cancellation,
        Map<String, Object?> extra = const {},
      }) => registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: tool,
        arguments: {
          'actorId': actor.id,
          'generation': actor.generation,
          ...extra,
        },
        expectedRevision: revision,
        idempotencyKey: '$tool/$revision/${extra['modelId']}',
        cancellation: cancellation,
      );
      final before = group.revision;
      expect((await call('inspect')).status, AgentStatus.ok);
      expect(group.revision, before);
      expect(worker.loads, 0);
      expect(worker.runs, 0);
      final mlResult = await registry.call(
        providerId: 'zyren_ml',
        instanceId: 'worker',
        tool: 'inspect',
      );
      expect(
        mlResult.data['resources'],
        containsPair('nativeArenaBytes', null),
      );
      expect(
        (await call('reset', revision: before)).status,
        AgentStatus.denied,
      );
      permits = true;
      expect(
        (await call('reset', revision: before - 1)).status,
        AgentStatus.stale,
      );
      final cancellation = AgentCancellation()..cancel();
      expect(
        (await call(
          'reset',
          revision: before,
          cancellation: cancellation,
        )).status,
        AgentStatus.cancelled,
      );
      expect(
        (await call('reset', revision: before)).status,
        AgentStatus.denied,
        reason: 'Idempotency preserves the prior rejected command.',
      );
      final reset = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'reset',
        arguments: {'actorId': actor.id, 'generation': actor.generation},
        expectedRevision: group.revision,
        idempotencyKey: 'permitted-reset',
      );
      expect(reset.status, AgentStatus.ok);
      expect(brain.state.version, 0);
      expect(group.revision, greaterThan(before));
      final denied = AgentRegistry();
      denied.register(provider);
      addTearDown(denied.dispose);
      expect(
        (await denied.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'inspect',
          arguments: {'actorId': actor.id, 'generation': actor.generation},
        )).status,
        AgentStatus.denied,
      );
      registration.dispose();
      expect((await call('inspect')).status, AgentStatus.unavailable);
    },
  );
  test(
    'cancelled or changed model preparation never commits an actor swap',
    () async {
      final f = PolicyFixture(), worker = DelayedWorker();
      final entered = Completer<void>(), bytes = Completer<Uint8List>();
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: worker,
          resolver: (_) {
            entered.complete();
            return bytes.future;
          },
        ),
        currentTick: () => 1,
      );
      final group = PolicyGroup(episodeId: 'ep', entities: f.entities, ml: ml);
      final actor = f.entities.spawn('actor');
      final first = fakeManifest(), next = fakeManifest(byte: 8, id: 'next');
      final oldContract = f.contract(first, ActionDecoder.character()),
          nextContract = f.contract(next, ActionDecoder.character());
      group.join(
        BrainIdentity(episodeId: 'ep', entity: actor, modelHash: first.sha256),
        oldContract,
      );
      final registry = AgentRegistry(grantedScopes: {'ai.control'});
      final provider = GameAiAgentProvider(
        instanceId: 'ep',
        host: GameAiPolicyHost(
          group: group,
          models: {'next': nextContract},
          permits: (_) => true,
          currentRevision: () => group.revision,
        ),
      );
      final registration = registry.register(provider);
      addTearDown(() async {
        registration.dispose();
        registry.dispose();
        await group.close();
        await ml.close();
      });
      final cancellation = AgentCancellation();
      final result = registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'select_model',
        arguments: {
          'actorId': actor.id,
          'generation': actor.generation,
          'modelId': 'next',
        },
        expectedRevision: group.revision,
        idempotencyKey: 'swap',
        cancellation: cancellation,
      );
      await entered.future;
      cancellation.cancel();
      bytes.complete(Uint8List.fromList([8]));
      expect((await result).status, AgentStatus.cancelled);
      expect(group.brainFor(actor)!.identity.modelHash, first.sha256);
      expect(ml.cache.diagnostics.leaseReferences, 0);
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'select_model',
          arguments: {
            'actorId': actor.id,
            'generation': actor.generation + 1,
            'modelId': 'next',
          },
          expectedRevision: group.revision,
          idempotencyKey: 'spoof',
        )).status,
        AgentStatus.stale,
      );
    },
  );
}
