import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';

BrainIdentity identity(
  String actor, {
  String episode = 'ep',
  String model = 'script-v1',
}) => BrainIdentity(
  episodeId: episode,
  entity: GameEntityHandle(actor, 1),
  modelHash: model,
);
void main() {
  test(
    'duplicate delivery cannot rewrite a capture or clear unknown state',
    () {
      final store = BeliefStore(identity: identity('a'));
      final target = GameEntityHandle('target', 1);
      store.observe(target: target, position: const Vec3(1, 0, 0), tick: 1);
      store.markUnknown(target, tick: 2);
      expect(
        store.observe(
          target: target,
          position: const Vec3(9, 0, 0),
          tick: 1,
          source: BeliefSource.team,
        ),
        isFalse,
      );
      expect(store.atTick(2).single.position, const Vec3(1, 0, 0));
      expect(store.stateAt(target, 2), BeliefKnowledge.unknown);
      store.forget(target);
      expect(store.stateAt(target, 2), BeliefKnowledge.unobserved);
    },
  );
  test('invalid restore leaves existing memory intact', () {
    final store = BeliefStore(identity: identity('a'));
    final target = GameEntityHandle('target', 1);
    store.observe(target: target, position: Vec3.zero, tick: 1);
    final json =
        jsonDecode(store.snapshot(tick: 1).encode()) as Map<String, dynamic>;
    (json['beliefs'] as List).single['ttlTicks'] = 100000;
    final bad = MemorySnapshot.decode(jsonEncode(json));
    expect(() => store.restore(bad, tick: 2), throwsArgumentError);
    expect(store.atTick(2).single.position, Vec3.zero);
  });

  test('serialized byte cap includes envelope and unknown timestamps', () {
    final store = BeliefStore(
      identity: identity('guard'),
      profile: MemoryProfile(maxSerializedBytes: 1000),
    );
    for (var i = 0; i < 30; i++) {
      final target = GameEntityHandle('target-$i', 1);
      store.observe(target: target, position: const Vec3(1, 0, -1), tick: 1);
      store.markUnknown(target, tick: 2);
    }
    expect(
      utf8.encode(store.snapshot(tick: 2).encode()).length,
      lessThanOrEqualTo(1000),
    );
    expect(store.diagnostics.accountedBytes, lessThanOrEqualTo(1000));
    expect(store.diagnostics.evictions, greaterThan(0));
  });

  test(
    'TTL preserves last seen location and distinguishes observation states',
    () {
      final store = BeliefStore(
        identity: identity('guard'),
        profile: MemoryProfile(ttlTicks: 10),
      );
      final target = GameEntityHandle('runner', 1);
      store.observe(target: target, position: const Vec3(2, 0, -3), tick: 10);
      expect(store.stateAt(target, 10), BeliefKnowledge.observed);
      expect(store.stateAt(target, 11), BeliefKnowledge.unobserved);
      store.markUnknown(target, tick: 12);
      expect(store.stateAt(target, 12), BeliefKnowledge.unknown);
      expect(store.atTick(20).single.position, const Vec3(2, 0, -3));
      expect(store.atTick(20).single.ageTicks, 10);
      expect(store.atTick(21), isEmpty);
      expect(store.stateAt(target, 21), BeliefKnowledge.expired);
    },
  );
  test(
    'actors own separate bounded memory, resets clear episode/model pins',
    () {
      final a = BeliefStore(
        identity: identity('a'),
        profile: MemoryProfile(maxBeliefs: 2),
      );
      final b = BeliefStore(identity: identity('b'));
      for (var i = 0; i < 4; i++) {
        a.observe(
          target: GameEntityHandle('t$i', 1),
          position: Vec3(i.toDouble(), 0, 0),
          tick: i,
        );
      }
      expect(a.atTick(4).map((b) => b.target!.id), ['t2', 't3']);
      expect(b.atTick(4), isEmpty);
      expect(a.diagnostics.retainedBeliefs, 2);
      a.reset(
        BrainReset(
          identity('a', model: 'script-v2'),
          BrainResetReason.modelChanged,
        ),
      );
      expect(a.atTick(5), isEmpty);
      a.observe(
        target: GameEntityHandle('runner', 1),
        position: Vec3.zero,
        tick: 6,
      );
      a.reset(
        BrainReset(
          identity('a', episode: 'next'),
          BrainResetReason.episodeChanged,
        ),
      );
      expect(a.atTick(7), isEmpty);
    },
  );
  test(
    'snapshot restore preserves ages relative to the saved tick and validates identity',
    () {
      final store = BeliefStore(
        identity: identity('a'),
        profile: MemoryProfile(ttlTicks: 20),
      );
      store.observe(
        target: GameEntityHandle('runner', 1),
        position: const Vec3(1, 0, 0),
        tick: 10,
      );
      final saved = MemorySnapshot.decode(store.snapshot(tick: 15).encode());
      final restored = BeliefStore(
        identity: identity('a'),
        profile: MemoryProfile(ttlTicks: 20),
      );
      restored.restore(saved, tick: 100);
      expect(restored.atTick(100).single.ageTicks, 5);
      expect(restored.atTick(116), isEmpty);
      expect(
        () => BeliefStore(identity: identity('b')).restore(saved, tick: 100),
        throwsArgumentError,
      );
    },
  );
  test(
    'team messages require authored permission, delivery delay and range',
    () {
      final recipient = BeliefStore(identity: identity('b'));
      final policy = TeamMemoryPolicy(teamId: 'blue', delayTicks: 3, range: 5);
      final message = TeamBeliefMessage(
        teamId: 'blue',
        sender: identity('a'),
        recipient: identity('b'),
        target: GameEntityHandle('runner', 1),
        position: const Vec3(2, 0, 0),
        observedTick: 1,
        sentTick: 2,
        ttlTicks: 10,
        confidence: .8,
      );
      expect(
        recipient.receive(
          message,
          policy: policy,
          tick: 4,
          senderDistance: 2,
          permitted: true,
        ),
        isFalse,
      );
      expect(
        recipient.receive(
          message,
          policy: policy,
          tick: 5,
          senderDistance: 6,
          permitted: true,
        ),
        isFalse,
      );
      expect(
        recipient.receive(
          message,
          policy: policy,
          tick: 5,
          senderDistance: 2,
          permitted: false,
        ),
        isFalse,
      );
      expect(
        recipient.receive(
          message,
          policy: policy,
          tick: 5,
          senderDistance: 2,
          permitted: true,
        ),
        isTrue,
      );
      final belief = recipient.atTick(5).single;
      expect(belief.position, const Vec3(2, 0, 0));
      expect(belief.source, BeliefSource.team);
      expect(belief.ageTicks, 4);
    },
  );
}
