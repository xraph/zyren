import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  test(
    'sensor phase captures one post-physics snapshot for all live actors',
    () async {
      final world = PhysicsWorld(gravity: Vec3.zero);
      final physics = PhysicsPlugin(
        world: world,
        externallyDriven: true,
        interpolate: false,
      );
      final registry = SensorRegistry()..register(BodySensor());
      final assembler = ObservationAssembler(
        registry: registry,
        profile: SensorProfile(),
      );
      final bindings = <GameEntityHandle, PhysicsBody>{};
      final frames = <ObservationFrame>[];
      var captures = 0;
      late GameSimulation simulation;
      final system = GamePerceptionSystem(
        simulation: () => simulation,
        assembler: assembler,
        actors: () => simulation.session.entities.entities.map((e) => e.handle),
        capture: (s) {
          captures++;
          return SensorSnapshot.fromSimulation(
            episodeId: 'episode',
            worldRevision: s.session.tick,
            simulation: s,
            bindings: bindings,
            colliders: {},
            currentRevision: () => s.session.tick,
            geometryLoaded: (_, _) => true,
          );
        },
        publish: frames.add,
      );
      final project = CompiledGameProject(
        project: GameProject(
          id: 'game',
          startupLevel: 'level',
          registry: GameRegistry(),
          levels: [
            GameLevel(
              id: 'level',
              scene: GameSceneIdentity('scene', 'pin'),
              entities: [],
            ),
          ],
        ),
      );
      simulation = GameSimulation(
        project: project,
        seed: 1,
        physics: physics,
        systems: [system],
        ownsWorld: true,
      );
      try {
        for (final id in ['a', 'b']) {
          final handle = simulation.session.entities.spawn(id);
          bindings[handle] = world.createBody(velocity: const Vec3(1, 0, 0));
        }
        simulation.step();
        expect(captures, 1);
        expect(frames.length, 2);
        expect(frames.map((f) => f.tick), [1, 1]);
        expect(frames.map((f) => f.worldRevision), [1, 1]);
        expect(
          bindings.values.first.state.pose.position.x,
          closeTo(1 / 60, 1e-6),
        );
        expect(frames.first.readings.single.values.first, 1);
        expect(frames.first.tensor.shape.last, assembler.spec.width);
        final stale = bindings.keys.first;
        simulation.session.entities.despawn(stale);
        final snapshot = SensorSnapshot.fromSimulation(
          episodeId: 'episode',
          worldRevision: 1,
          simulation: simulation,
          bindings: bindings,
          colliders: {},
          currentRevision: () => 1,
          geometryLoaded: (_, _) => true,
        );
        expect(snapshot.entities.containsKey(stale), isFalse);
      } finally {
        await simulation.close();
      }
    },
  );
}
