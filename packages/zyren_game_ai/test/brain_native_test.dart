import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_physics/zyren_physics.dart';
import '../../zyren_game_native/test/support/character_fixture.dart';
import '../../zyren_game_native/test/support/vehicle_fixture.dart';

BrainContext permitted(
  BrainIdentity id,
  int tick, {
  bool driver = false,
  Set<GameEntityHandle> targets = const {},
}) => BrainContext(
  identity: id,
  tick: tick,
  beliefs: [],
  goals: [],
  validTargets: targets,
  actionSpec: driver
      ? ScriptedBrain.driverActions
      : ScriptedBrain.characterActions,
);
ObservationAssembler assemble(GameSensor sensor, SensorProfile profile) =>
    ObservationAssembler(
      registry: SensorRegistry()..register(sensor),
      profile: profile,
    );
void move(GameCharacterFixture f, BrainDecision d) {
  expect(d.isApplicable(f.simulation.session.entities, d.identity), isTrue);
  final args = d.actions.single.arguments;
  f.controller.apply(
    CharacterIntent(
      moveX: args['moveX'] as double,
      moveZ: args['moveZ'] as double,
    ),
  );
}

void main() {
  test(
    'native guard remembers the captured position after loss of sight',
    () async {
      final f = await GameCharacterFixture.create();
      addTearDown(f.close);
      final actor = f.controller.actor;
      final target = f.simulation.session.entities.spawn('runner');
      final body = f.world.createBody(
        kind: BodyKind.fixed,
        pose: PhysicsPose(position: const Vec3(0, .81, -2)),
      );
      final targetCollider = body.addCollider(const SphereShape(.1));
      final metadata = <int, SensorCollider>{
        targetCollider.id: SensorCollider(
          SensorMaterial.opaque,
          entity: target,
        ),
      };
      final id = BrainIdentity(
        episodeId: 'guard',
        entity: actor,
        modelHash: 'script-v1',
      );
      final brain = ScriptedBrain(
        identity: id,
        entities: f.simulation.session.entities,
        memoryProfile: MemoryProfile(ttlTicks: 4),
      );
      addTearDown(brain.close);
      final profile = SensorProfile(range: 15, maxEntities: 2);
      final assembler = assemble(VisionSensor(profile), profile);
      ObservationFrame frame() => assembler.build(
        SensorSnapshot.fromSimulation(
          episodeId: id.episodeId,
          worldRevision: 1,
          simulation: f.simulation,
          bindings: {actor: f.body, target: body},
          colliders: metadata,
          characters: [f.controller],
          currentRevision: () => 1,
          geometryLoaded: (_, _) => true,
        ),
        actor,
      );
      f.step();
      brain.observe(frame());
      final seen = brain.memory.atTick(f.simulation.session.tick).single;
      move(
        f,
        brain.decide(
          permitted(id, f.simulation.session.tick, targets: {target}),
        ),
      );
      final before = f.body.state.pose.position.z;
      f.step();
      expect(f.body.state.pose.position.z, lessThan(before));
      final wall = f.world.createBody(
        kind: BodyKind.fixed,
        pose: PhysicsPose(position: const Vec3(0, 1, -4)),
      );
      metadata[wall.addCollider(const BoxShape(Vec3(5, 2, .1))).id] =
          const SensorCollider(SensorMaterial.opaque);
      body.teleport(PhysicsPose(position: const Vec3(2, .81, -8)));
      f.step();
      final hidden = frame();
      expect(hidden.visibleIds, isEmpty);
      brain.observe(hidden);
      final remembered = brain.memory.atTick(hidden.tick).single;
      expect(remembered.position, seen.position);
      expect(remembered.ageTicks, 2);
      // Structured vision reports incomplete catalog coverage as unknown.
      expect(remembered.knowledge, BeliefKnowledge.unknown);
      expect(
        brain.decide(permitted(id, hidden.tick, targets: {target})).goal!.skill,
        'investigate',
      );
      body.teleport(PhysicsPose(position: const Vec3(-3, .81, -9)));
      f.step();
      brain.observe(frame());
      expect(
        brain.memory.atTick(f.simulation.session.tick).single.position,
        seen.position,
      );
      f.step(3);
      brain.observe(frame());
      expect(
        brain.memory.stateAt(target, f.simulation.session.tick),
        BeliefKnowledge.expired,
      );
      expect(
        brain
            .decide(permitted(id, f.simulation.session.tick, targets: {target}))
            .goal!
            .skill,
        'idle',
      );
    },
  );

  test(
    'native guard investigates uncertain audible cues without source identity',
    () async {
      final f = await GameCharacterFixture.create();
      addTearDown(f.close);
      final actor = f.controller.actor;
      final wall = f.world.createBody(
        kind: BodyKind.fixed,
        pose: PhysicsPose(position: const Vec3(0, 1, -3)),
      );
      final collider = wall.addCollider(const BoxShape(Vec3(4, 2, .1)));
      final profile = SensorProfile(range: 15);
      final assembler = assemble(HearingSensor(profile, maxSounds: 1), profile);
      final id = BrainIdentity(
        episodeId: 'sound',
        entity: actor,
        modelHash: 'script-v1',
      );
      final brain = ScriptedBrain(
        identity: id,
        entities: f.simulation.session.entities,
      );
      addTearDown(brain.close);
      f.step();
      final tick = f.simulation.session.tick;
      final frame = assembler.build(
        SensorSnapshot.fromSimulation(
          episodeId: id.episodeId,
          worldRevision: 1,
          simulation: f.simulation,
          bindings: {actor: f.body},
          colliders: {collider.id: const SensorCollider(SensorMaterial.opaque)},
          currentRevision: () => 1,
          geometryLoaded: (_, _) => true,
          sounds: [
            GameSoundEvent(
              id: 'cue',
              category: 'footstep',
              tick: tick,
              position: const Vec3(0, .81, -6),
              loudness: 1,
              range: 20,
              sourceEntityId: 'private-source',
            ),
          ],
        ),
        actor,
      );
      expect(frame.readings.single.sounds.single.obstructed, isTrue);
      brain.observe(frame);
      final belief = brain.memory.atTick(tick).single;
      expect(belief.target, isNull);
      expect(belief.position, isNull);
      expect(belief.sound!.bearingUncertaintyRadians, greaterThan(0));
      final decision = brain.decide(permitted(id, tick));
      expect(decision.goal!.skill, 'investigate');
      move(f, decision);
      final before = f.body.state.pose.position.z;
      f.step(3);
      expect(f.body.state.pose.position.z, lessThan(before));
    },
  );

  test(
    'native driver brakes for an obstacle and for unknown geometry',
    () async {
      final f = await VehicleFixture.create();
      addTearDown(f.close);
      f.step(120);
      final id = BrainIdentity(
        episodeId: 'drive',
        entity: f.actor,
        modelHash: 'script-v1',
      );
      final brain = ScriptedBrain(
        identity: id,
        entities: f.simulation.session.entities,
        driver: true,
      );
      addTearDown(brain.close);
      final profile = SensorProfile(range: 12);
      final assembler = assemble(
        RaySensor(profile, directions: [const Vec3(0, 0, 1)]),
        profile,
      );
      final metadata = <int, SensorCollider>{};
      var loaded = true;
      ObservationFrame frame() => assembler.build(
        SensorSnapshot.fromSimulation(
          episodeId: id.episodeId,
          worldRevision: 1,
          simulation: f.simulation,
          bindings: {f.actor: f.body},
          colliders: metadata,
          currentRevision: () => 1,
          geometryLoaded: (_, _) => loaded,
        ),
        f.actor,
      );
      void apply(BrainDecision d) {
        expect(d.isApplicable(f.simulation.session.entities, id), isTrue);
        final a = d.actions.single.arguments;
        f.controller.apply(
          VehicleIntent(
            throttle: a['throttle'] as double,
            brake: a['brake'] as double,
            steer: a['steering'] as double,
          ),
        );
      }

      brain.observe(frame());
      final clear = brain.decide(
        permitted(id, f.simulation.session.tick, driver: true),
      );
      expect(clear.actions.single.arguments['throttle'], .5);
      apply(clear);
      f.step(20);
      expect(f.body.state.velocity.z, greaterThan(.2));
      final wall = f.world.createBody(
        kind: BodyKind.fixed,
        pose: PhysicsPose(
          position: f.body.state.pose.position + const Vec3(0, 0, 2),
        ),
      );
      metadata[wall.addCollider(const BoxShape(Vec3(2, 2, .1))).id] =
          const SensorCollider(SensorMaterial.opaque);
      f.step();
      brain.observe(frame());
      final blocked = brain.decide(
        permitted(id, f.simulation.session.tick, driver: true),
      );
      expect(blocked.actions.single.arguments['brake'], 1);
      apply(blocked);
      final speed = f.body.state.velocity.length;
      f.step(20);
      expect(f.body.state.velocity.length, lessThan(speed));
      loaded = false;
      brain.observe(frame());
      final unknown = brain.decide(
        permitted(id, f.simulation.session.tick, driver: true),
      );
      expect(unknown.actions.single.arguments['brake'], 1);
    },
  );
}
