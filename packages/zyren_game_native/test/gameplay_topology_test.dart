import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_native/gameplay.dart';
import 'runtime_test.dart' as fixture;

Future<
  ({GameLevelRuntime runtime, SceneEngine engine, GameLevelGameplay gameplay})
>
start() async {
  final scene = Scene(), camera = PerspectiveCamera();
  late GameLevelGameplay gameplay;
  final runtime = GameLevelRuntime(
    project: fixture.project(),
    scene: scene,
    camera: camera,
    objects: fixture.objects(scene),
    systemFactory: (runtime) => [
      gameplay = GameLevelGameplay(runtime, GameRuleLibrary()),
    ],
  );
  await runtime.initialize();
  final engine = await SceneEngine.create(
    scene: scene,
    camera: camera,
    rendererFactory: () async => fixture.RuntimeRenderer(),
    plugins: runtime.plugins,
  );
  runtime.simulation!.step();
  return (runtime: runtime, engine: engine, gameplay: gameplay);
}

GameSpawnTemplate pickup(GameLevelRuntime r, {String id = 'pool-touch'}) =>
    GameSpawnTemplate(
      id: 'pickup',
      registry: r.project.project.registry,
      entities: [
        GameEntityRecord(
          id: 'item',
          nodeId: 'item',
          components: [
            GameComponentRecord(
              'game.collider',
              1,
              GameColliderDefinition(
                shape: GameColliderShape.sphere,
                radius: .2,
              ).toJson(),
            ),
            GameComponentRecord(
              'game.inventory',
              1,
              Inventory(capacity: 8, items: {'coin': 2}).toJson(),
            ),
            GameComponentRecord(
              'game.interaction',
              1,
              GameInteractionDefinition(id: id, reach: 3).toJson(),
            ),
          ],
        ),
      ],
    );
Future<GameRuntimeSpawnInstance> prepare(
  GameLevelRuntime r,
  String instance, {
  String id = 'pool-touch',
}) => r.prepareSpawn(
  pickup(r, id: id),
  instanceId: instance,
  prepare: (records) async => GameRuntimeSpawnResources(
    objects: {
      records.single.nodeId!: Group()..position = const Vec3(0, 1.5, 1),
    },
  ),
);

final class RejectLater extends GameStateCodec<bool> {
  @override
  String get id => 'test.topology-later';
  @override
  int get version => 1;
  @override
  Map<String, Object?> capture(GameSession session) => {'fail': false};
  @override
  bool prepare(GameSession session, Map<String, Object?> data) =>
      data['fail'] as bool;
  @override
  void commit(GameSession session, bool prepared) {
    if (prepared) throw StateError('Later topology commit rejected.');
  }
}

void main() {
  test(
    'pooled native interaction binds each fresh generation and preserves survivor inventory',
    () async {
      final f = await start(), r = f.runtime, gameplay = f.gameplay;
      try {
        final player = r.inputActor!,
            owner = gameplay.authored.gameplay.actor(r.inputActor!)!;
        owner.inventory.add('key', 2);
        final baseline = r.world!.states.length;
        final slot = await prepare(r, 'pickup');
        for (var i = 0; i < 50; i++) {
          final queued = r.enqueueSpawn(slot);
          r.simulation!.step();
          expect(await queued, isTrue);
          final target = slot.handles.single;
          expect(gameplay.available(player).single.target, target);
          expect(gameplay.authored.hasItem(target, 'coin', 2), isTrue);
          expect(gameplay.interact(player, 'pool-touch'), isTrue);
          r.simulation!.step();
          expect(
            gameplay.authored.interactionApplied(player, 'pool-touch'),
            isTrue,
          );
          expect(gameplay.authored.gameplay.actor(player), same(owner));
          final retiring = r.enqueueDespawn(slot);
          r.simulation!.step();
          expect(await retiring, isTrue);
          expect(gameplay.available(player), isEmpty);
          expect(gameplay.interact(player, 'pool-touch'), isFalse);
          expect(gameplay.authored.gameplay.actor(target), isNull);
          expect(gameplay.authored.hasItem(player, 'key', 2), isTrue);
          expect(r.world!.states.length, baseline + 1);
        }
        r.pause();
        await r.releaseSpawn(slot);
        expect(r.world!.states.length, baseline);
      } finally {
        await f.engine.dispose();
        await r.close();
      }
    },
  );
  test(
    'dormant prepared interaction restores inventory and fresh queries with atomic duplicate preflight',
    () async {
      final f = await start(), r = f.runtime, gameplay = f.gameplay;
      try {
        final slot = await prepare(r, 'pickup');
        final queued = r.enqueueSpawn(slot);
        r.simulation!.step();
        expect(await queued, isTrue);
        final target = slot.handles.single;
        gameplay.authored.gameplay.actor(target)!.inventory.add('coin', 1);
        var allocations = 0;
        final bodies = r.world!.states.length, player = r.inputActor!;
        expect(
          () => r.prepareSpawn(
            pickup(r),
            instanceId: 'duplicate',
            prepare: (records) async {
              allocations++;
              return GameRuntimeSpawnResources(
                objects: {records.single.nodeId!: Group()},
              );
            },
          ),
          throwsStateError,
        );
        expect(allocations, 0);
        expect(r.world!.states.length, bodies);
        expect(gameplay.available(player).single.target, target);
        r.pause();
        final save = r.save();
        final corrupted = jsonDecode(save.encode()) as Map<String, dynamic>;
        final entity = (corrupted['entities'] as List).cast<Map>().singleWhere(
          (e) => e['id'] == target.id,
        );
        final component = (entity['components'] as List)
            .cast<Map>()
            .singleWhere((c) => c['type'] == 'game.interaction');
        (component['data'] as Map)['id'] = 'forged-interaction';
        expect(
          () => r.restore(GameSave.decode(jsonEncode(corrupted))),
          throwsFormatException,
        );
        expect(r.error, isNull);
        expect(slot.handles.single, target);
        expect(gameplay.authored.gameplay.interactions.keys, ['pool-touch']);
        r.retireSpawn(slot);
        expect(gameplay.authored.gameplay.actor(target), isNull);
        r.restore(save);
        final fresh = slot.handles.single;
        expect(fresh, isNot(target));
        expect(gameplay.authored.hasItem(fresh, 'coin', 3), isTrue);
        r.resume();
        expect(gameplay.available(player), isEmpty);
        expect(gameplay.available(r.inputActor!).single.target, fresh);
        expect(gameplay.interact(r.inputActor!, 'pool-touch'), isTrue);
        r.simulation!.step();
        expect(
          gameplay.authored.interactionApplied(r.inputActor!, 'pool-touch'),
          isTrue,
        );
        r.pause();
        r.retireSpawn(slot);
        final absent = r.save();
        r.activateSpawn(slot);
        r.restore(absent);
        r.resume();
        expect(slot.isActive, isFalse);
        expect(gameplay.available(r.inputActor!), isEmpty);
      } finally {
        await f.engine.dispose();
        await r.close();
      }
    },
  );
  test(
    'later codec rejection rolls changed authored and native topology back jointly',
    () async {
      final f = await start(), r = f.runtime, gameplay = f.gameplay;
      try {
        final later = RejectLater();
        r.simulation!.session.registerStateCodec(later);
        final slot = await prepare(r, 'pickup');
        final queued = r.enqueueSpawn(slot);
        r.simulation!.step();
        expect(await queued, isTrue);
        r.pause();
        final saved = r.save();
        r.retireSpawn(slot);
        final player = r.inputActor!, body = r.resolveBody(r.inputActor!)!;
        gameplay.authored.gameplay.actor(player)!.inventory.add('key', 2);
        final pose = body.state.pose.position;
        final data = jsonDecode(saved.encode()) as Map<String, dynamic>;
        (data['state'] as Map)[later.id] = {'fail': true};
        expect(
          () => r.restore(GameSave.decode(jsonEncode(data))),
          throwsStateError,
        );
        expect(r.error, isNull);
        expect(r.inputActor, player);
        expect(slot.isActive, isFalse);
        expect(body.state.pose.position, pose);
        expect(gameplay.authored.hasItem(player, 'key', 2), isTrue);
        expect(gameplay.authored.gameplay.interactions, isEmpty);
        r.resume();
        expect(gameplay.available(player), isEmpty);
        final retry = r.enqueueSpawn(slot);
        r.simulation!.step();
        expect(await retry, isTrue);
        expect(gameplay.available(player).single.target, slot.handles.single);
        expect(gameplay.authored.hasItem(player, 'key', 2), isTrue);
      } finally {
        await f.engine.dispose();
        await r.close();
      }
    },
  );
}
