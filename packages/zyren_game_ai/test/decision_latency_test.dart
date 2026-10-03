import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import '../../zyren_ml/test/support/delayed_worker.dart' show fakeManifest;

void main() {
  test(
    'target eligibility revocation rejects a live target before state commit',
    () {
      final entities = GameEntityTable();
      final actor = entities.spawn('actor'), target = entities.spawn('target');
      final model = fakeManifest();
      final state = PolicyState(model);
      final id = BrainIdentity(
        episodeId: 'ep',
        entity: actor,
        modelHash: model.sha256,
      );
      final decoder = ActionDecoder.character();
      final scheduler = DecisionScheduler(
        identity: id,
        entities: entities,
        decoder: decoder,
        state: state,
      );
      final candidate = BrainDecision.policy(
        identity: id,
        observationTick: 1,
        applyTick: 2,
        actionSchemaHash: decoder.spec.hash,
        action: PolicyAction([.5, 0], []),
        nextHiddenState: {},
        baseStateVersion: state.version,
        stateEpoch: state.epoch,
        target: target,
      );
      expect(scheduler.stage(candidate), isTrue);
      expect(entities.isAlive(target), isTrue);
      expect(scheduler.atTick(2, validTargets: {}).isFallback, isTrue);
      expect(state.version, 0);
      expect(
        scheduler.accept(candidate, tick: 2, validTargets: {target}),
        isTrue,
      );
      expect(scheduler.atTick(3, validTargets: {}).isFallback, isTrue);
    },
  );

  test(
    'execution legality cannot reuse a captured mask for a recurrent action',
    () {
      final entities = GameEntityTable();
      final actor = entities.spawn('actor');
      final model = fakeManifest();
      final state = PolicyState(model);
      final id = BrainIdentity(
        episodeId: 'ep',
        entity: actor,
        modelHash: model.sha256,
      );
      final decoder = ActionDecoder.character(jump: true);
      final scheduler = DecisionScheduler(
        identity: id,
        entities: entities,
        decoder: decoder,
        state: state,
      );
      final candidate = BrainDecision.policy(
        identity: id,
        observationTick: 1,
        applyTick: 2,
        actionSchemaHash: decoder.spec.hash,
        action: PolicyAction([.5, 0], [1]),
        nextHiddenState: {},
        baseStateVersion: state.version,
        stateEpoch: state.epoch,
      );
      expect(
        scheduler.stage(
          candidate,
          legality: [
            [true, true],
          ],
        ),
        isTrue,
      );
      expect(
        scheduler
            .atTick(
              2,
              legality: [
                [true, false],
              ],
            )
            .isFallback,
        isTrue,
      );
      expect(state.version, 0);
      expect(scheduler.currentAction.character!.jump, isFalse);
      expect(scheduler.accept(candidate, tick: 2), isFalse);
    },
  );

  test(
    'snapshot invalidation rejects an old candidate even when epochs repeat',
    () {
      final entities = GameEntityTable();
      final actor = entities.spawn('actor');
      final model = fakeManifest();
      final id = BrainIdentity(
        episodeId: 'ep',
        entity: actor,
        modelHash: model.sha256,
      );
      final decoder = ActionDecoder.character(), state = PolicyState(model);
      final scheduler = DecisionScheduler(
        identity: id,
        entities: entities,
        decoder: decoder,
        state: state,
      );
      final old = BrainDecision.policy(
        identity: id,
        observationTick: 1,
        applyTick: 2,
        actionSchemaHash: decoder.spec.hash,
        action: PolicyAction([.5, 0], []),
        nextHiddenState: {},
        baseStateVersion: state.version,
        stateEpoch: state.epoch,
      );
      scheduler.invalidatePending();
      expect(scheduler.accept(old, tick: 2), isFalse);
      expect(state.version, 0);
    },
  );

  test(
    'due action and hidden state commit together with exact ownership pins',
    () {
      final entities = GameEntityTable();
      final actor = entities.spawn('actor');
      final model = fakeManifest();
      final id = BrainIdentity(
        episodeId: 'ep',
        entity: actor,
        modelHash: model.sha256,
      );
      final decoder = ActionDecoder.character();
      final state = PolicyState(model);
      final scheduler = DecisionScheduler(
        identity: id,
        entities: entities,
        decoder: decoder,
        state: state,
        maxHoldTicks: 1,
      );
      BrainDecision candidate({int epoch = 0, int control = 0, String? hash}) =>
          BrainDecision.policy(
            identity: hash == null
                ? id
                : BrainIdentity(
                    episodeId: 'ep',
                    entity: actor,
                    modelHash: hash,
                  ),
            observationTick: 1,
            applyTick: 3,
            gameEpoch: epoch,
            controlEpoch: control,
            actionSchemaHash: decoder.spec.hash,
            action: PolicyAction([.5, 0], []),
            nextHiddenState: const {},
            baseStateVersion: 0,
            stateEpoch: state.epoch,
          );
      expect(scheduler.accept(candidate(), tick: 2), isFalse);
      expect(state.version, 0);
      expect(scheduler.accept(candidate(control: 1), tick: 3), isFalse);
      expect(scheduler.accept(candidate(hash: 'wrong'), tick: 3), isFalse);
      expect(scheduler.accept(candidate(), tick: 3), isTrue);
      expect(state.version, 1);
      expect(scheduler.atTick(4).policyAction!.continuous[0], .5);
      state.reset();
      expect(scheduler.atTick(4).isFallback, isTrue);
      expect(scheduler.atTick(5).isFallback, isTrue);
      expect(scheduler.currentAction.character!.moveX, 0);
      scheduler.synchronize(gameEpoch: 1, controlEpoch: 1, paused: true);
      expect(scheduler.accept(candidate(), tick: 3), isFalse);
      expect(state.version, 0);
    },
  );
  test(
    'missed ticks and despawned targets reject action and recurrent state',
    () {
      final entities = GameEntityTable();
      final actor = entities.spawn('actor'), target = entities.spawn('target');
      final model = fakeManifest();
      final id = BrainIdentity(
        episodeId: 'ep',
        entity: actor,
        modelHash: model.sha256,
      );
      final decoder = ActionDecoder.vehicle(), state = PolicyState(model);
      final scheduler = DecisionScheduler(
        identity: id,
        entities: entities,
        decoder: decoder,
        state: state,
      );
      final candidate = BrainDecision.policy(
        identity: id,
        observationTick: 1,
        applyTick: 2,
        actionSchemaHash: decoder.spec.hash,
        action: PolicyAction([0, .5], []),
        nextHiddenState: const {},
        baseStateVersion: 0,
        stateEpoch: state.epoch,
        target: target,
      );
      expect(scheduler.accept(candidate, tick: 3), isFalse);
      entities.despawn(target);
      entities.spawn('target');
      expect(scheduler.accept(candidate, tick: 2), isFalse);
      expect(state.version, 0);
      expect(scheduler.atTick(4).isFallback, isTrue);
      expect(scheduler.currentAction.vehicle!.brake, 1);
    },
  );
}
