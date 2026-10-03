import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_interaction/zyren_interaction.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'support/character_fixture.dart';

void main() {
  test(
    'policy callbacks can retire a target without stale execution or iterator errors',
    () async {
      final f = await GameCharacterFixture.create();
      final router = SceneInteractionRouter(
        scene: f.scene,
        camera: () => PerspectiveCamera(),
        viewport: () => const ViewportMetrics(328, 700),
      );
      final target = f.simulation.session.entities.spawn('target');
      final body = f.box(const Vec3(0, .81, 1), const Vec3(.2, .2, .2));
      var retire = false, actions = 0;
      late Registration lease;
      final query = InteractionQuery(
        session: f.simulation.session,
        world: f.world,
        router: router,
        resolveBody: (actor) => actor == f.controller.actor ? f.body : body,
        canInteract: (actor, target) {
          if (retire) {
            lease.dispose();
            f.simulation.session.entities.despawn(target);
          }
          return true;
        },
      );
      try {
        lease = query.register(
          target: target,
          object: f.scene.add(Group()),
          body: body,
          id: 'use',
          label: 'Use',
          onExecute: (_) => actions++,
        );
        final candidate = query.available(f.controller.actor).single;
        retire = true;
        expect(query.available(f.controller.actor), isEmpty);
        expect(query.execute(f.controller.actor, candidate), isFalse);
        expect(actions, 0);
      } finally {
        query.close();
        router.dispose();
        await f.close();
      }
    },
  );
  test(
    'native candidates share pointer routing and remain bounded at narrow widths',
    () async {
      final f = await GameCharacterFixture.create();
      final camera = PerspectiveCamera(
        position: const Vec3(0, .81, .8),
        target: const Vec3(0, .81, 2),
      );
      var width = 328.0;
      final router = SceneInteractionRouter(
        scene: f.scene,
        camera: () => camera,
        viewport: () => ViewportMetrics(width, 700),
      );
      final bodies = <GameEntityHandle, PhysicsBody>{
        f.controller.actor: f.body,
      };
      final query = InteractionQuery(
        session: f.simulation.session,
        world: f.world,
        router: router,
        resolveBody: (h) => bodies[h],
        pointerActor: () => f.controller.actor,
        maxCandidates: 1,
        maxTargets: 2,
      );
      final leases = <Registration>[];
      var actions = 0;
      try {
        for (final index in [0, 1]) {
          final target = f.simulation.session.entities.spawn('target$index');
          final position = Vec3(index * .5, .81, 1.5);
          final body = f.box(position, const Vec3(.15, .2, .15));
          bodies[target] = body;
          final object = f.scene.add(
            Mesh(
              BoxGeometry(width: .3, height: .4, depth: .3),
              UnlitMaterial(),
            ),
          )..position = position;
          leases.add(
            query.register(
              target: target,
              object: object,
              body: body,
              id: 'use',
              label: 'Use',
              onExecute: (_) => actions++,
            ),
          );
        }
        expect(query.available(f.controller.actor), hasLength(1));
        expect(query.available(f.controller.actor).single.target.id, 'target0');
        final extra = f.simulation.session.entities.spawn('extra');
        final body = f.box(const Vec3(1, .81, 1.5), const Vec3(.1, .1, .1));
        expect(
          () => query.register(
            target: extra,
            object: f.scene.add(Group()),
            body: body,
            id: 'use',
            label: 'Use',
            onExecute: (_) => actions++,
          ),
          throwsStateError,
        );
        for (final size in [1280.0, 396.0, 328.0]) {
          width = size;
          router.dispatch(
            ScenePointerEvent(
              point: ViewportPoint(width / 2, 350),
              phase: ScenePointerPhase.tap,
            ),
          );
        }
        expect(actions, 3);
        final candidate = query.available(f.controller.actor).single;
        f.simulation.session.entities.despawn(f.controller.actor);
        expect(query.execute(f.controller.actor, candidate), isFalse);
      } finally {
        for (final lease in leases) {
          lease.dispose();
        }
        query.close();
        router.dispose();
        await f.close();
      }
    },
  );
  test(
    'interaction execution rechecks target generation, reach, line of sight and scene membership',
    () async {
      final f = await GameCharacterFixture.create();
      final router = SceneInteractionRouter(
        scene: f.scene,
        camera: () => PerspectiveCamera(),
        viewport: () => const ViewportMetrics(328, 700),
      );
      InteractionQuery? query;
      Registration? lease;
      try {
        final session = f.simulation.session;
        final target = session.entities.spawn('door');
        final targetBody = f.box(
          const Vec3(0, .81, 1.5),
          const Vec3(.2, .3, .2),
        );
        final object = f.scene.add(Group());
        final bodies = <GameEntityHandle, PhysicsBody>{
          f.controller.actor: f.body,
          target: targetBody,
        };
        var actions = 0;
        query = InteractionQuery(
          session: session,
          world: f.world,
          router: router,
          resolveBody: (h) => bodies[h],
          reach: 2,
          maxCandidates: 1,
        );
        lease = query.register(
          target: target,
          object: object,
          body: targetBody,
          id: 'open',
          label: 'Open',
          onExecute: (actor) => actions++,
        );
        var candidate = query.available(f.controller.actor).single;
        expect(query.execute(f.controller.actor, candidate), isTrue);
        expect(actions, 1);
        final wall = f.box(const Vec3(0, .81, .7), const Vec3(2, 1, .05));
        expect(query.execute(f.controller.actor, candidate), isFalse);
        expect(query.available(f.controller.actor), isEmpty);
        wall.remove();
        candidate = query.available(f.controller.actor).single;
        targetBody.teleport(PhysicsPose(position: const Vec3(0, .81, 4)));
        expect(query.execute(f.controller.actor, candidate), isFalse);
        targetBody.teleport(PhysicsPose(position: const Vec3(0, .81, 1.5)));
        candidate = query.available(f.controller.actor).single;
        session.entities.despawn(target);
        final replacement = session.entities.spawn(target.id);
        expect(replacement.generation, greaterThan(target.generation));
        expect(query.execute(f.controller.actor, candidate), isFalse);
        expect(actions, 1);
        lease.dispose();
        lease = query.register(
          target: replacement,
          object: object,
          body: targetBody,
          id: 'open',
          label: 'Open',
          onExecute: (actor) => actions++,
        );
        bodies[replacement] = targetBody;
        candidate = query.available(f.controller.actor).single;
        f.scene.remove(object);
        expect(query.execute(f.controller.actor, candidate), isFalse);
        expect(actions, 1);
      } finally {
        lease?.dispose();
        query?.close();
        router.dispose();
        await f.close();
      }
    },
  );
}
