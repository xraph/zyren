import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  test('cone and range boundaries operate in the sensor local frame', () {
    final p = SensorProfile(range: 10, halfAngleRadians: math.pi / 4);
    expect(p.contains(const Vec3(0, 0, -10)), isTrue);
    expect(p.contains(Vec3(1, 0, -1).normalized() * 10), isTrue);
    expect(p.contains(const Vec3(1.001, 0, -1)), isFalse);
    expect(p.contains(const Vec3(0, 0, -10.01)), isFalse);
    expect(p.contains(const Vec3(0, 0, 1)), isFalse);
  });
  test(
    'real Rapier wall occludes and paired hidden worlds yield identical tensors',
    () {
      List<int> capture(double hiddenX) {
        final f = Fixture();
        try {
          f.entity('visible', const Vec3(0, 0, -2));
          f.entity('behind-wall', Vec3(hiddenX, 0, -8));
          f.obstacle(const Vec3(0, 0, -5), const Vec3(4, 2, .2));
          f.world.step();
          final frame = f.frame();
          expect(frame.visibleIds, ['visible']);
          expect(frame.entities.length, 2);
          expect(frame.entityMask, [1, 0]);
          expect(frame.schemaHash, f.assembler.spec.hash);
          return frame.tensor.bytes.toList();
        } finally {
          f.world.close();
        }
      }

      expect(capture(-1), capture(2));
    },
  );
  test(
    'glass and foliage need an explicit pass/block policy; missing metadata stays unknown',
    () {
      for (final material in [SensorMaterial.glass, SensorMaterial.foliage]) {
        final f = Fixture();
        try {
          f.entity('target', const Vec3(0, 0, -8));
          f.obstacle(
            const Vec3(0, 0, -4),
            const Vec3(2, 2, .1),
            material: material,
          );
          f.world.step();
          expect(f.frame().visibleIds, isEmpty);
          expect(f.frame().readings.single.state, SensorState.unknown);
          expect(
            f.frame(materials: {material: SensorMaterialRule.pass}).visibleIds,
            ['target'],
          );
          expect(
            f.frame(materials: {material: SensorMaterialRule.block}).visibleIds,
            isEmpty,
          );
        } finally {
          f.world.close();
        }
      }
    },
  );
  test(
    'moving doors, unloaded segments, disappearance and budgets never invent clear rays',
    () {
      final f = Fixture();
      try {
        f.entity('target', const Vec3(0, 0, -8));
        final door = f.obstacle(const Vec3(0, 0, -4), const Vec3(1, 2, .2));
        f.world.step();
        expect(f.frame().visibleIds, isEmpty);
        door.teleport(PhysicsPose(position: const Vec3(5, 0, -4)));
        f.revision++;
        f.world.step();
        expect(f.frame().visibleIds, ['target']);
        f.loaded = false;
        expect(f.frame().readings.single.state, SensorState.unknown);
        expect(f.frame().entityMask, [0, 0]);
        f.loaded = true;
        expect(
          f.frame(queryBudget: 0).readings.single.state,
          SensorState.unknown,
        );
        f.bindings.remove(GameEntityHandle('target', 1))!.remove();
        f.revision++;
        f.world.step();
        expect(f.frame().visibleIds, isEmpty);
      } finally {
        f.world.close();
      }
    },
  );
  test(
    'layer filters are explicit and unclassified colliders remain unknown',
    () {
      final f = Fixture();
      try {
        f.entity('target', const Vec3(0, 0, -8));
        final wall = f.world.createBody(
          kind: BodyKind.fixed,
          pose: PhysicsPose(position: const Vec3(0, 0, -4)),
        );
        final collider = wall.addCollider(
          const BoxShape(Vec3(2, 2, .1)),
          membership: 2,
        );
        f.world.step();
        final unknown = VisionSensor(
          SensorProfile(range: 10),
        ).sample(f.snapshot(), f.actor);
        expect(unknown.state, SensorState.unknown);
        expect(unknown.entities, isEmpty);
        f.colliders[collider.id] = const SensorCollider(SensorMaterial.opaque);
        final filtered = VisionSensor(
          SensorProfile(range: 10, layerMask: 1),
        ).sample(f.snapshot(), f.actor);
        expect(filtered.entities.single.handle.id, 'target');
      } finally {
        f.world.close();
      }
    },
  );
  test('stable bounded visible slots and masks ignore insertion order', () {
    final f = Fixture();
    try {
      f.entity('z', const Vec3(0, 0, -2));
      f.entity('a', const Vec3(1, 0, -3));
      f.entity('b', const Vec3(-1, 0, -3));
      f.world.step();
      expect(f.frame().visibleIds, ['a', 'b']);
      expect(f.frame().entityMask, [1, 1]);
    } finally {
      f.world.close();
    }
  });
  test(
    'snapshot revision invalidates all readings and rotated poses use local coordinates',
    () {
      final f = Fixture();
      try {
        f.entity('target', const Vec3(2, 0, 0));
        f.bindings[f.actor]!.teleport(
          PhysicsPose(
            rotation: Quat.axisAngle(const Vec3(0, 1, 0), -math.pi / 2),
          ),
        );
        f.world.step();
        final snapshot = f.snapshot();
        final frame = f.assembler.build(snapshot, f.actor);
        expect(frame.visibleIds, ['target']);
        expect(frame.entities.first!.localPosition.z, closeTo(-2, 1e-5));
        f.revision++;
        expect(
          f.assembler.build(snapshot, f.actor).readings.single.state,
          SensorState.unknown,
        );
      } finally {
        f.world.close();
      }
    },
  );
}

class Fixture {
  final world = PhysicsWorld(gravity: Vec3.zero);
  final actor = GameEntityHandle('actor', 1);
  final bindings = <GameEntityHandle, PhysicsBody>{};
  final colliders = <int, SensorCollider>{};
  var revision = 1;
  var loaded = true;
  late ObservationAssembler assembler;
  Fixture() {
    entity('actor', Vec3.zero);
    assembler = makeAssembler();
  }
  PhysicsBody entity(String id, Vec3 position) {
    final h = GameEntityHandle(id, 1);
    final b = world.createBody(
      kind: BodyKind.fixed,
      pose: PhysicsPose(position: position),
    );
    final c = b.addCollider(const SphereShape(.1));
    bindings[h] = b;
    colliders[c.id] = SensorCollider(SensorMaterial.opaque, entity: h);
    return b;
  }

  PhysicsBody obstacle(
    Vec3 position,
    Vec3 extents, {
    SensorMaterial material = SensorMaterial.opaque,
  }) {
    final b = world.createBody(
      kind: BodyKind.fixed,
      pose: PhysicsPose(position: position),
    );
    final c = b.addCollider(BoxShape(extents));
    colliders[c.id] = SensorCollider(material);
    return b;
  }

  ObservationAssembler makeAssembler({
    Map<SensorMaterial, SensorMaterialRule> materials = const {},
    int queryBudget = 32,
  }) {
    final registry = SensorRegistry();
    final profile = SensorProfile(
      range: 10,
      maxEntities: 2,
      queryBudget: queryBudget,
      materials: materials,
    );
    registry.register(VisionSensor(profile));
    return ObservationAssembler(registry: registry, profile: profile);
  }

  SensorSnapshot snapshot() => SensorSnapshot.fromPhysics(
    episodeId: 'episode',
    tick: 1,
    worldRevision: revision,
    world: world,
    bindings: bindings,
    colliders: colliders,
    currentRevision: () => revision,
    geometryLoaded: (_, _) => loaded,
  );
  ObservationFrame frame({
    Map<SensorMaterial, SensorMaterialRule> materials = const {},
    int queryBudget = 32,
  }) => makeAssembler(
    materials: materials,
    queryBudget: queryBudget,
  ).build(snapshot(), actor);
}
