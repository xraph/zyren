import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_navigation/zyren_navigation.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'topology_test.dart' as fixture;

void main() {
  final receipts = <String, Object?>{};
  tearDownAll(() async {
    final destination = Platform.environment['GAME_FAILURE_RECEIPT_PATH'];
    if (destination == null || receipts.length != 2) return;
    final file = File(destination);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'schemaVersion': 1, 'cases': receipts}),
    );
  });
  void record(
    String name,
    String actual,
    String recovery,
    Map<String, Object?> before,
    Map<String, Object?> after,
    Map<String, int> baseline,
    Map<String, int> cleanup,
  ) {
    expect(after, before);
    expect(cleanup, baseline);
    receipts[name] = {
      'status': 'passed',
      'actualStatus': actual,
      'before': before,
      'after': after,
      'cleanupCounters': {'before': baseline, 'after': cleanup},
      'recovery': {'action': recovery, 'status': 'passed'},
      'execution': {
        'kind': 'native',
        'exitCode': 0,
        'command':
            'cd packages/zyren_game_native && fvm dart test test/failure_receipts_test.dart',
      },
    };
  }

  test(
    'native cancellation preserves the paused host and releases late assets before retry',
    () async {
      final counts = PhysicsWorld.nativeCounts;
      final f = await fixture.start(), r = f.runtime;
      final entered = Completer<void>(), release = Completer<void>();
      var retainedAssets = 0;
      Map<String, Object?> identity() => {
        'session': r.project.project.id,
        'epoch': r.simulation!.session.epoch,
        'handles': r.simulation!.session.entities.entities
            .map((e) => {'id': e.handle.id, 'generation': e.handle.generation})
            .toList(),
        'bodies': r.world!.states.map((s) => s.id).toList(),
        'pool': r.spawnPoolSize,
        'playerNode': identityHashCode(r.objects['player']),
      };
      late Map<String, Object?> before, after;
      try {
        final preparing = r.prepareSpawn(
          fixture.npc(r),
          instanceId: 'late',
          prepare: (records) async {
            entered.complete();
            await release.future;
            retainedAssets++;
            return GameRuntimeSpawnResources(
              objects: {records.single.nodeId!: Group()},
              resources: [
                GameRuntimeResourceLease(close: () => retainedAssets--),
              ],
            );
          },
        );
        final rejected = expectLater(preparing, throwsStateError);
        await entered.future;
        r.pause();
        before = identity();
        release.complete();
        await rejected;
        after = identity();
        expect(retainedAssets, 0);
        final slot = await r.prepareSpawn(
          fixture.npc(r),
          instanceId: 'late',
          prepare: (records) async => GameRuntimeSpawnResources(
            objects: {
              records.single.nodeId!: Group()..position = const Vec3(2, 1.5, 0),
            },
          ),
        );
        r.activateSpawn(slot);
        r.resume();
        final actor = slot.handles.single,
            body = r.resolveBody(slot.handles.single)!;
        final z = body.state.pose.position.z;
        final control = r.acquireActorControl(actor)!;
        control.applyCharacter(const CharacterIntent(moveZ: 1));
        r.simulation!.step();
        expect(body.state.pose.position.z, greaterThan(z));
      } finally {
        if (!release.isCompleted) release.complete();
        await f.engine.dispose();
        await r.close();
      }
      record(
        'cancellation',
        'rejected',
        'retry_native_spawn',
        before,
        after,
        {...counts, 'retainedAssets': 0},
        {...PhysicsWorld.nativeCounts, 'retainedAssets': retainedAssets},
      );
    },
  );

  test(
    'native replacement obstacle invalidates an old route and resumes only from a fresh route',
    () async {
      final counts = PhysicsWorld.nativeCounts;
      final f = await fixture.start(), r = f.runtime;
      late Map<String, Object?> before, after;
      try {
        final slot = await r.prepareSpawn(
          fixture.npc(r),
          instanceId: 'navigator',
          prepare: (records) async => GameRuntimeSpawnResources(
            objects: {
              records.single.nodeId!: Group()
                ..position = const Vec3(-2, 1.5, 0),
            },
          ),
        );
        final spawned = r.enqueueSpawn(slot);
        r.simulation!.step();
        expect(await spawned, isTrue);
        final actor = slot.handles.single,
            body = r.resolveBody(slot.handles.single)!;
        final floor = Mesh(
          BoxGeometry(width: 6, height: .2, depth: 6),
          UnlitMaterial(),
        )..position = const Vec3(0, -.1, 0);
        final nav = NavigationWorld(
          NavigationBaker().bake([
            NavigationGeometry.fromMesh(
              floor,
              sourceId: 'floor',
              revision: '1',
            ),
          ]),
        );
        final follower = NavigationFollower(nav)..setGoal(const Vec3(2, 0, 0));
        const feet = Vec3(-2, 0, 0);
        expect(follower.intent(feet, .1).length, greaterThan(0));
        final old = follower.route!;
        final removed = r.world!.createBody(
          kind: BodyKind.fixed,
          pose: PhysicsPose(position: const Vec3(0, 1, 0)),
        );
        removed.addCollider(const BoxShape(Vec3(.4, 1, .4)));
        removed.remove();
        final wall = r.world!.createBody(
          kind: BodyKind.fixed,
          pose: PhysicsPose(position: const Vec3(0, 1, 0)),
        );
        wall.addCollider(const BoxShape(Vec3(.4, 1, 3)));
        final hit = r.world!.rayCast(
          origin: const Vec3(-1, 1, 0),
          direction: const Vec3(1, 0, 0),
          maxDistance: 2,
        )!;
        expect(hit.body, wall.id);
        nav.setObstacles([
          NavigationObstacle(
            'body-${wall.id}',
            min: const Vec3(-.4, 0, -3),
            max: const Vec3(.4, 2, 3),
          ),
        ]);
        expect(nav.isCurrent(old), isFalse);
        Map<String, Object?> identity() => {
          'actor': {'id': actor.id, 'generation': actor.generation},
          'body': body.id,
          'obstacleBody': wall.id,
          'goal': follower.goal!.storage,
          'staleRouteRevision': old.revision,
          'positionX': body.state.pose.position.x,
          'positionZ': body.state.pose.position.z,
        };
        before = identity();
        final movement = follower.intent(feet, .1);
        expect(movement, Vec3.zero);
        expect(follower.route!.status, RouteStatus.disconnected);
        final control = r.acquireActorControl(actor)!;
        control.applyCharacter(const CharacterIntent());
        r.simulation!.step();
        after = identity();
        wall.remove();
        nav.setObstacles([]);
        expect(nav.isCurrent(old), isFalse);
        final fresh = follower.intent(feet, .1);
        expect(fresh.length, greaterThan(0));
        expect(nav.isCurrent(follower.route!), isTrue);
        final initial = body.state.pose.position;
        control.applyCharacter(
          CharacterIntent(
            moveX: fresh.x / fresh.length,
            moveZ: fresh.z / fresh.length,
          ),
        );
        r.simulation!.step();
        final travelled = body.state.pose.position - initial;
        expect(travelled.x * fresh.x + travelled.z * fresh.z, greaterThan(0));
      } finally {
        await f.engine.dispose();
        await r.close();
      }
      record(
        'leakage.stale-nav',
        'rejected',
        'replan_after_obstacle_removal',
        before,
        after,
        counts,
        PhysicsWorld.nativeCounts,
      );
    },
  );
}
