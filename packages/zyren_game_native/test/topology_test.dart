import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'runtime_test.dart' as fixture;
import 'support/vehicle_fixture.dart' show buggyDefinition;
import 'package:zyren_game_native/animation.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import '../../../examples/game_lab/assets/skinned_character_asset.dart';

GameSpawnTemplate npc(GameLevelRuntime runtime) => GameSpawnTemplate(
  id: 'guard',
  registry: runtime.project.project.registry,
  entities: [
    GameEntityRecord(
      id: 'npc',
      nodeId: 'npc',
      components: runtime.project.levels.single.entities.last.components
          .where((c) => c.type != 'game.input' && c.type != 'game.camera')
          .toList(),
    ),
  ],
);

Future<({GameLevelRuntime runtime, SceneEngine engine})> start({
  bool animated = false,
}) async {
  final scene = Scene(), camera = PerspectiveCamera();
  final runtime = GameLevelRuntime(
    project: fixture.project(),
    scene: scene,
    camera: camera,
    objects: fixture.objects(scene),
    maxPreparedSpawns: 2,
    animationFactory: animated ? createGameCharacterAnimation : null,
  );
  await runtime.initialize();
  final engine = await SceneEngine.create(
    scene: scene,
    camera: camera,
    rendererFactory: () async => fixture.RuntimeRenderer(),
    plugins: runtime.plugins,
  );
  runtime.simulation!.step();
  return (runtime: runtime, engine: engine);
}

final class PendingCodec extends GameStateCodec<Object> {
  @override
  String get id => 'test.pending';
  @override
  int get version => 1;
  @override
  Map<String, Object?> capture(GameSession session) =>
      throw StateError('Inference pending');
  @override
  Object prepare(GameSession session, Map<String, Object?> data) => Object();
  @override
  void commit(GameSession session, Object prepared) {}
}

void main() {
  test(
    'prepared NPC pool activates on commands and retains one physical owner across 50 lifetimes',
    () async {
      final f = await start(), runtime = f.runtime;
      var preparations = 0, closes = 0;
      final changes = <GameRuntimeTopologyChange>[];
      final listener = runtime.listenTopology(changes.add);
      try {
        final baseline = runtime.world!.states.length;
        final slot = await runtime.prepareSpawn(
          npc(runtime),
          instanceId: 'guard-1',
          prepare: (records) async {
            preparations++;
            return GameRuntimeSpawnResources(
              objects: {
                records.single.nodeId!: Group()
                  ..position = const Vec3(2, 1.5, 0),
              },
              resources: [GameRuntimeResourceLease(close: () => closes++)],
            );
          },
        );
        expect(
          runtime.entityDefinition(slot.records.single.id),
          same(slot.records.single),
        );
        final player = runtime.inputActor!;
        for (var i = 0; i < 50; i++) {
          final spawning = runtime.enqueueSpawn(slot);
          expect(slot.isActive, isFalse);
          runtime.simulation!.step();
          expect(await spawning, isTrue);
          final actor = slot.handles.single;
          final control = runtime.acquireActorControl(actor)!;
          control.applyCharacter(const CharacterIntent(moveZ: 1));
          runtime.simulation!.step();
          expect(
            runtime.resolveBody(actor)!.state.pose.position.z,
            greaterThan(.05),
            reason:
                "lifetime $i at ${runtime.resolveBody(actor)!.state.pose.position}",
          );
          final retiring = runtime.enqueueDespawn(slot);
          runtime.simulation!.step();
          expect(await retiring, isTrue);
          expect(control.isActive, isFalse);
          expect(runtime.resolveBody(actor), isNull);
          expect(runtime.world!.states.length, baseline + 1);
          expect(runtime.inputActor, player);
          expect(runtime.controlledActor, player);
        }
        expect(preparations, 1);
        expect(changes, hasLength(100));
        runtime.pause();
        await runtime.releaseSpawn(slot);
        expect(runtime.world!.states.length, baseline);
        expect(runtime.spawnPoolSize, 0);
        expect(runtime.entityDefinition(slot.records.single.id), isNull);
        expect(closes, 1);
      } finally {
        listener.dispose();
        await f.engine.dispose();
        await runtime.close();
      }
    },
  );

  test(
    'dynamic native checkpoint restores a compatible prepared recipe and fresh generation',
    () async {
      final f = await start(), runtime = f.runtime;
      try {
        final slot = await runtime.prepareSpawn(
          npc(runtime),
          instanceId: 'guard-1',
          prepare: (records) async => GameRuntimeSpawnResources(
            objects: {
              records.single.nodeId!: Group()..position = const Vec3(2, 1.5, 0),
            },
          ),
        );
        final spawning = runtime.enqueueSpawn(slot);
        runtime.simulation!.step();
        expect(await spawning, isTrue);
        final old = slot.handles.single,
            body = runtime.resolveBody(slot.handles.single)!;
        final control = runtime.acquireActorControl(old)!;
        control.applyCharacter(const CharacterIntent(moveZ: 1));
        runtime.simulation!.step();
        runtime.pause();
        final save = runtime.save(), position = body.state.pose.position;
        runtime.retireSpawn(slot);
        expect(slot.isActive, isFalse);
        runtime.restore(GameSave.decode(save.encode()));
        final fresh = slot.handles.single;
        expect(fresh, isNot(old));
        expect(runtime.resolveBody(fresh), same(body));
        expect(body.state.pose.position, position);
        expect(runtime.resolveBody(old), isNull);
        expect(slot.isActive, isTrue);
        runtime.resume();
        expect(runtime.acquireActorControl(fresh), isNotNull);
      } finally {
        await f.engine.dispose();
        await runtime.close();
      }
    },
  );

  test(
    'close waits for asynchronous spawn preparation and releases cancelled resources once',
    () async {
      final f = await start(), runtime = f.runtime;
      final entered = Completer<void>(), release = Completer<void>();
      var closes = 0;
      final preparing = runtime.prepareSpawn(
        npc(runtime),
        instanceId: 'late',
        prepare: (records) async {
          entered.complete();
          await release.future;
          return GameRuntimeSpawnResources(
            objects: {records.single.nodeId!: Group()},
            resources: [
              GameRuntimeResourceLease(
                close: () {
                  expect(runtime.world!.isClosed, isFalse);
                  closes++;
                },
              ),
            ],
          );
        },
      );
      final rejected = expectLater(preparing, throwsStateError);
      await entered.future;
      await f.engine.dispose();
      var closed = false;
      final closing = runtime.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      release.complete();
      await rejected;
      await closing;
      expect(closes, 1);
      expect(runtime.spawnPoolSize, 0);
    },
  );

  test(
    'pool capacity and foreign nodes reject before replacing owned scene resources',
    () async {
      final f = await start(), r = f.runtime;
      var closes = 0;
      try {
        final baseline = r.world!.states.length, player = r.objects['player']!;
        await expectLater(
          r.prepareSpawn(
            npc(r),
            instanceId: 'foreign',
            prepare: (records) async => GameRuntimeSpawnResources(
              objects: {'player': player, records.single.nodeId!: Group()},
              resources: [GameRuntimeResourceLease(close: () => closes++)],
            ),
          ),
          throwsArgumentError,
        );
        expect(r.objects['player'], same(player));
        expect(player.parent, same(r.scene));
        expect(r.world!.states.length, baseline);
        expect(closes, 1);
        final slots = <GameRuntimeSpawnInstance>[];
        for (var i = 0; i < 2; i++) {
          slots.add(
            await r.prepareSpawn(
              npc(r),
              instanceId: 'slot$i',
              prepare: (records) async => GameRuntimeSpawnResources(
                objects: {
                  records.single.nodeId!: Group()
                    ..position = const Vec3(2, 1.5, 0),
                },
              ),
            ),
          );
        }
        expect(
          () => r.prepareSpawn(
            npc(r),
            instanceId: 'overflow',
            prepare: (_) async => throw StateError('must not prepare'),
          ),
          throwsStateError,
        );
        final queued = r.enqueueSpawn(slots.first);
        r.pause();
        expect(await queued, isFalse);
        r.resume();
        r.simulation!.step();
        expect(slots.first.isActive, isFalse);
        r.pause();
        for (final slot in slots) {
          await r.releaseSpawn(slot);
        }
        expect(r.world!.states.length, baseline);
      } finally {
        await f.engine.dispose();
        await r.close();
      }
    },
  );

  test(
    'failed partial physics setup rolls back and a fresh compatible host restores prepared recipe',
    () async {
      final f = await start(), r = f.runtime;
      GameSave? saved;
      try {
        final baseline = r.world!.states.length;
        final original = npc(r).entities.single;
        final broken = GameSpawnTemplate(
          id: 'partial',
          registry: r.project.project.registry,
          entities: [
            original,
            GameEntityRecord(
              id: 'second',
              nodeId: 'second',
              components: original.components
                  .map(
                    (c) => c.type == 'game.collider'
                        ? GameComponentRecord(c.type, c.version, {
                            ...c.data,
                            'motion': 'dynamic',
                          })
                        : c,
                  )
                  .toList(),
            ),
          ],
        );
        var released = 0;
        await expectLater(
          r.prepareSpawn(
            broken,
            instanceId: 'bad',
            prepare: (records) async => GameRuntimeSpawnResources(
              objects: {
                for (final record in records)
                  record.nodeId!: Group()..position = const Vec3(2, 1.5, 0),
              },
              resources: [
                GameRuntimeResourceLease(
                  close: () {
                    released++;
                    expect(r.world!.states.length, baseline);
                  },
                ),
              ],
            ),
          ),
          throwsStateError,
        );
        expect(released, 1);
        expect(r.world!.states.length, baseline);
        expect(r.objects.keys.where((k) => k.startsWith('bad/')), isEmpty);
        final slot = await r.prepareSpawn(
          npc(r),
          instanceId: 'guard-1',
          prepare: (records) async => GameRuntimeSpawnResources(
            objects: {
              records.single.nodeId!: Group()..position = const Vec3(2, 1.5, 0),
            },
          ),
        );
        final added = r.enqueueSpawn(slot);
        r.simulation!.step();
        await added;
        r.pause();
        saved = r.save();
      } finally {
        await f.engine.dispose();
        await r.close();
      }
      final next = await start(), host = next.runtime;
      try {
        final before = host.save().encode(),
            epoch = host.simulation!.session.epoch;
        expect(() => host.restore(saved!), throwsFormatException);
        expect(host.save().encode(), before);
        expect(host.simulation!.session.epoch, epoch);
        final slot = await host.prepareSpawn(
          npc(host),
          instanceId: 'guard-1',
          prepare: (records) async => GameRuntimeSpawnResources(
            objects: {
              records.single.nodeId!: Group()..position = const Vec3(2, 1.5, 0),
            },
          ),
        );
        host.restore(saved);
        expect(slot.isActive, isTrue);
        expect(host.resolveBody(slot.handles.single), isNotNull);
      } finally {
        await next.engine.dispose();
        await host.close();
      }
    },
  );

  test(
    'pooled vehicle reuses body, wheel visuals and checkpoint handling',
    () async {
      final f = await start(), r = f.runtime;
      try {
        final template = GameSpawnTemplate(
          id: 'buggy',
          registry: r.project.project.registry,
          entities: [
            GameEntityRecord(
              id: 'buggy',
              nodeId: 'buggy',
              components: [
                GameComponentRecord(
                  'game.collider',
                  1,
                  GameColliderDefinition(
                    motion: GameBodyMotion.dynamic,
                    halfExtents: const Vec3(.7, .25, 1),
                  ).toJson(),
                ),
                GameComponentRecord(
                  'game.vehicle',
                  1,
                  buggyDefinition().toJson(),
                ),
              ],
            ),
          ],
        );
        final slot = await r.prepareSpawn(
          template,
          instanceId: 'car',
          prepare: (records) async => GameRuntimeSpawnResources(
            objects: {
              records.single.nodeId!: Group()..position = const Vec3(3, .8, 0),
            },
          ),
        );
        for (var lifetime = 0; lifetime < 3; lifetime++) {
          final added = r.enqueueSpawn(slot);
          r.simulation!.step();
          await added;
          final actor = slot.handles.single,
              body = r.resolveBody(slot.handles.single)!;
          final lease = r.acquireActorControl(actor)!;
          lease.applyVehicle(const VehicleIntent(throttle: 1));
          for (var i = 0; i < 40; i++) {
            r.simulation!.step();
          }
          expect(body.state.pose.position.z, greaterThan(.1));
          expect(r.vehicles[actor]!.forceTicks, 41);
          expect(r.objects[slot.records.single.nodeId]!.children, hasLength(4));
          r.pause();
          final saved = r.save(), handling = r.vehicles[actor]!.captureState();
          r.retireSpawn(slot);
          expect(lease.isActive, isFalse);
          expect(r.objects[slot.records.single.nodeId]!.children, isEmpty);
          r.restore(saved);
          expect(r.vehicles[slot.handles.single]!.captureState(), handling);
          r.retireSpawn(slot);
          r.resume();
        }
        r.pause();
        await r.releaseSpawn(slot);
      } finally {
        await f.engine.dispose();
        await r.close();
      }
    },
  );

  test(
    'pooled imported motor retains one attached animation owner through reuse and save',
    () async {
      final f = await start(animated: true), r = f.runtime;
      final assets = AssetScope(
        services: AssetServices(resolver: SkinnedCharacterSource()),
      );
      final source = await assets.load(Gltf.asset('skin.gltf')).result;
      final attached = [...r.plugins];
      var engineAlive = true;
      try {
        final recipe = GameSpawnTemplate(
          id: 'rig',
          registry: r.project.project.registry,
          entities: [
            GameEntityRecord(
              id: 'npc',
              nodeId: 'npc',
              components: [
                ...npc(r).entities.single.components,
                GameComponentRecord(
                  'game.character-rig',
                  1,
                  GameCharacterRigDefinition(
                    rootMotionNode: 0,
                    movingClip: 'walk',
                  ).toJson(),
                ),
              ],
            ),
          ],
        );
        var attachedCount = 0, detached = 0;
        final slot = await r.prepareSpawn(
          recipe,
          instanceId: 'animated',
          prepare: (records) async => GameRuntimeSpawnResources(
            objects: {
              records.single.nodeId!: Group()
                ..position = const Vec3(2, 1.5, 0)
                ..add(source.instantiate(nativeDeformation: false)),
            },
            attachPlugins: (plugins) async {
              attachedCount++;
              attached.addAll(plugins);
              await f.engine.updatePlugins(attached);
              return GameRuntimeResourceLease(
                close: () async {
                  detached++;
                  attached.removeWhere(plugins.contains);
                  if (engineAlive) await f.engine.updatePlugins(attached);
                },
              );
            },
          ),
        );
        Object? motor;
        for (var i = 0; i < 3; i++) {
          final added = r.enqueueSpawn(slot);
          r.simulation!.step();
          await added;
          final actor = slot.handles.single,
              controller = r.animatedCharacters[slot.handles.single]!;
          motor ??= controller.motor;
          expect(controller.motor, same(motor));
          r
              .acquireActorControl(actor)!
              .applyCharacter(const CharacterIntent(moveZ: 1));
          for (var j = 0; j < 5; j++) {
            r.simulation!.step();
          }
          expect(r.resolveBody(actor)!.state.pose.position.z, greaterThan(.01));
          r.pause();
          final save = r.save(), state = controller.motor.captureState();
          r.retireSpawn(slot);
          r.restore(save);
          expect(
            r.animatedCharacters[slot.handles.single]!.motor.captureState(),
            state,
          );
          r.retireSpawn(slot);
          r.resume();
        }
        expect(attachedCount, 1);
        r.pause();
        await r.releaseSpawn(slot);
        expect(detached, 1);
      } finally {
        await f.engine.dispose();
        await r.close();
        await assets.close();
      }
    },
  );

  test(
    'spawn boundary bypasses pending save codecs and validates before allocation and activation',
    () async {
      final f = await start(), r = f.runtime;
      final codec = r.simulation!.session.registerStateCodec(PendingCodec());
      var allowed = false, preparations = 0, checks = 0;
      final validator = r.registerSpawnValidator((records) {
        checks++;
        if (!allowed) throw StateError('Actor policy unavailable');
      });
      try {
        Future<GameRuntimeSpawnResources> prepare(
          List<GameEntityRecord> records,
        ) async {
          preparations++;
          return GameRuntimeSpawnResources(
            objects: {
              records.single.nodeId!: Group()..position = const Vec3(2, 1.5, 0),
            },
          );
        }

        expect(() => r.save(), throwsStateError);
        expect(
          () => r.prepareSpawn(npc(r), instanceId: 'guard', prepare: prepare),
          throwsStateError,
        );
        expect(preparations, 0);
        allowed = true;
        final slot = await r.prepareSpawn(
          npc(r),
          instanceId: 'guard',
          prepare: prepare,
        );
        r.pause();
        allowed = false;
        expect(() => r.activateSpawn(slot), throwsStateError);
        expect(slot.isActive, isFalse);
        expect(r.error, isNull);
        allowed = true;
        r.resume();
        final adding = r.enqueueSpawn(slot);
        r.simulation!.step();
        expect(await adding, isTrue);
        expect(checks, 4);
        expect(preparations, 1);
        r.pause();
        r.retireSpawn(slot);
        await r.releaseSpawn(slot);
      } finally {
        validator.dispose();
        codec.cancel();
        await f.engine.dispose();
        await r.close();
      }
    },
  );

  test(
    'resource lifecycle and failing topology callback stop work while remaining closable',
    () async {
      final f = await start(), r = f.runtime;
      var pauses = 0, resumes = 0, closes = 0;
      try {
        final slot = await r.prepareSpawn(
          npc(r),
          instanceId: 'guard',
          prepare: (records) async => GameRuntimeSpawnResources(
            objects: {
              records.single.nodeId!: Group()..position = const Vec3(2, 1.5, 0),
            },
            resources: [
              GameRuntimeResourceLease(
                close: () => closes++,
                pause: () => pauses++,
                resume: () => resumes++,
              ),
            ],
          ),
        );
        final adding = r.enqueueSpawn(slot);
        r.simulation!.step();
        expect(await adding, isTrue);
        expect(resumes, 1);
        final count = pauses;
        r.pause();
        expect(pauses, count + 1);
        r.resume();
        expect(resumes, 2);
        final failure = r.listenTopology(
          (_) => throw StateError('Host reconcile failed'),
        );
        final retiring = r.enqueueDespawn(slot),
            rejected = expectLater(retiring, throwsStateError);
        expect(() => r.simulation!.step(), throwsStateError);
        await rejected;
        expect(r.error, isNotNull);
        expect(r.simulation!.physics.paused, isTrue);
        expect(slot.isActive, isFalse);
        failure.dispose();
      } finally {
        await f.engine.dispose();
        await r.close();
      }
      expect(closes, 1);
      expect(r.spawnPoolSize, 0);
    },
  );
}
