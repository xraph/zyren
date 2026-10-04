import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_ai/runtime.dart';
import 'runtime_native_test.dart' as fixture;

GameSpawnTemplate recipe(fixture.RuntimeFixture f, {String? modelHash}) {
  final source = f.runtime.project.levels.single.entities.singleWhere(
    (e) => e.id == 'npc',
  );
  return GameSpawnTemplate(
    id: 'reinforcement',
    registry: f.runtime.project.project.registry,
    entities: [
      GameEntityRecord(
        id: 'npc',
        nodeId: 'npc',
        components: [
          for (final c in source.components)
            if (c.type == 'game.ai' && modelHash != null)
              GameComponentRecord(c.type, c.version, {
                ...c.data,
                'modelHash': modelHash,
              })
            else
              c,
        ],
      ),
    ],
  );
}

void main() {
  test('checkpoint requires the complete live handle map', () async {
    final f = fixture.RuntimeFixture(brain: 'learned');
    await f.start();
    try {
      await f.step();
      final saved = await f.ai.save();
      final actor = f.npc, body = f.runtime.resolveBody(f.npc);
      final brain = f.ai.group!.brainFor(actor);
      for (final addUnknown in [false, true]) {
        final encoded = jsonDecode(saved.encode()) as Map<String, dynamic>;
        final handles = encoded['state']['game.ai.runtime']['handles'] as Map;
        if (addUnknown) {
          handles['unprepared'] = 1;
        } else {
          handles.remove(handles.keys.firstWhere((id) => id != actor.id));
        }
        await expectLater(
          f.ai.restore(GameSave.decode(jsonEncode(encoded))),
          throwsFormatException,
        );
        expect(f.npc, actor);
        expect(f.runtime.resolveBody(actor), same(body));
        expect(f.ai.group!.brainFor(actor), same(brain));
        expect(f.runtime.error, isNull);
        expect(f.runtime.save().encode(), saved.encode());
      }
      await f.ai.restore(saved);
      expect(f.npc.generation, greaterThan(actor.generation));
    } finally {
      await f.close();
    }
  });

  test(
    'changed checkpoint AI definition rolls back before native rebinding',
    () async {
      final f = fixture.RuntimeFixture(brain: 'learned');
      await f.start();
      try {
        await f.step();
        final save = await f.ai.save();
        final actor = f.npc,
            body = f.runtime.resolveBody(f.npc),
            brain = f.ai.group!.brainFor(f.npc);
        final encoded = jsonDecode(save.encode()) as Map<String, dynamic>;
        final npc = (encoded['entities'] as List).cast<Map>().singleWhere(
          (e) => e['id'] == 'npc',
        );
        final ai = (npc['components'] as List).cast<Map>().singleWhere(
          (c) => c['type'] == 'game.ai',
        );
        (ai['data'] as Map)['modelHash'] = '0' * 64;
        await expectLater(
          f.ai.restore(GameSave.decode(jsonEncode(encoded))),
          throwsFormatException,
        );
        expect(f.npc, actor);
        expect(f.runtime.resolveBody(actor), same(body));
        expect(f.ai.group!.brainFor(actor), same(brain));
        expect(f.runtime.error, isNull);
        await f.ai.restore(save);
        expect(f.npc.generation, greaterThan(actor.generation));
      } finally {
        await f.close();
      }
    },
  );

  test(
    'native AI pooling preserves other brains and restores a different active topology',
    () async {
      final f = fixture.RuntimeFixture(brain: 'learned');
      await f.start();
      try {
        await f.step();
        final survivor = f.npc;
        final survivorBrain = f.ai.group!.brainFor(survivor)!;
        final slot = await f.runtime.prepareSpawn(
          recipe(f),
          instanceId: 'backup',
          prepare: (records) async => GameRuntimeSpawnResources(
            objects: {
              records.single.nodeId!: Group()..position = const Vec3(3, 1.5, 0),
            },
          ),
        );
        GameEntityHandle? previous;
        for (var i = 0; i < 3; i++) {
          final version = survivorBrain.state.version;
          final spawned = f.runtime.enqueueSpawn(slot);
          await f.step();
          expect(await spawned, isTrue);
          final actor = slot.handles.single;
          expect(f.ai.actors, contains(actor));
          expect(f.ai.group!.brainFor(survivor), same(survivorBrain));
          // Resume first reacquires control and samples a fresh observation.
          // Pool activation must preserve committed state through that boundary.
          expect(survivorBrain.state.version, greaterThanOrEqualTo(version));
          expect(f.ai.group!.stateFor(actor)!.version, 0);
          if (previous != null) {
            expect(actor.generation, greaterThan(previous.generation));
            expect(() => f.ai.observation(previous!), throwsStateError);
          }
          for (var tick = 0; tick < 5; tick++) {
            await f.step();
          }
          expect(survivorBrain.state.version, greaterThan(version));
          expect(f.ai.group!.stateFor(actor)!.version, greaterThan(0));
          final saved = await f.ai.save();
          final state = f.ai.group!.stateFor(actor)!.version;
          f.runtime.retireSpawn(slot);
          await f.ai.flush();
          expect(f.ai.actors, [survivor]);
          if (i == 2) {
            await f.ai.restore(saved);
            final fresh = slot.handles.single;
            expect(fresh.generation, greaterThan(actor.generation));
            expect(f.ai.actors, contains(fresh));
            expect(f.ai.group!.stateFor(fresh)!.version, state);
          } else {
            f.runtime.resume();
          }
          previous = actor;
        }
      } finally {
        await f.close();
      }
    },
  );

  test(
    'unprepared learned model rejects before native spawn allocation',
    () async {
      final f = fixture.RuntimeFixture(brain: 'learned');
      await f.start();
      try {
        final bodies = f.runtime.world!.states.length;
        final actor = f.npc, brain = f.ai.group!.brainFor(f.npc);
        var preparations = 0;
        await expectLater(
          Future.sync(
            () => f.runtime.prepareSpawn(
              recipe(f, modelHash: '0' * 64),
              instanceId: 'bad',
              prepare: (_) async {
                preparations++;
                return GameRuntimeSpawnResources(objects: {});
              },
            ),
          ),
          throwsStateError,
        );
        expect(preparations, 0);
        expect(f.runtime.world!.states.length, bodies);
        expect(f.ai.actors, [actor]);
        expect(f.ai.group!.brainFor(actor), same(brain));
      } finally {
        await f.close();
      }
    },
  );
}
