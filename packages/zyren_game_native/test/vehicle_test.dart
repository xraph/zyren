import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'support/vehicle_fixture.dart';
import 'support/native_game_fixture.dart';
import 'support/character_fixture.dart';

void main() {
  test('definition validates geometry and immutable authored units', () {
    final definition = buggyDefinition();
    expect(VehicleDefinition.fromJson(definition.toJson()).wheelbase, 2);
    expect(() => definition.wheels.clear(), throwsUnsupportedError);
    expect(
      () => VehicleDefinition(wheels: [definition.wheels.first]),
      throwsArgumentError,
    );
    expect(
      () => const VehicleIntent(throttle: double.nan).validate(),
      throwsArgumentError,
    );
  });

  test(
    'vehicle system rejects a different presentation physics owner',
    () async {
      final world = PhysicsWorld();
      addTearDown(world.close);
      final physics = PhysicsPlugin(world: world, externallyDriven: true);
      final otherPhysics = PhysicsPlugin(world: world, externallyDriven: true);
      final vehicles = GameVehicleSystem(world: world, physics: otherPhysics);
      final simulation = GameSimulation(
        project: testProject(),
        seed: 1,
        physics: physics,
        systems: [vehicles, GameVehiclePresentationSystem(vehicles)],
      );
      addTearDown(simulation.close);
      expect(simulation.step, throwsStateError);
      expect(simulation.session.tick, 0);
    },
  );
  test(
    'fresh chassis initializes mass without an extra physics step',
    () async {
      final f = await VehicleFixture.create();
      addTearDown(f.close);
      final actor = f.simulation.session.entities.spawn('fresh');
      final body = f.world.createBody(
        pose: PhysicsPose(position: const Vec3(5, .8, 0)),
        mass: 400,
        inertia: const Vec3(200, 277, 94),
        canSleep: false,
      );
      body.addCollider(const BoxShape(Vec3(.8, .25, 1.2)), density: 0);
      final controller = VehicleController(
        session: f.simulation.session,
        actor: actor,
        body: body,
        definition: buggyDefinition(),
      );
      final root = f.scene.add(Group());
      f.vehicles.register(
        controller,
        presentationRoot: root,
        wheelVisuals: [for (var i = 0; i < 4; i++) root.add(Group())],
      );
      controller.apply(const VehicleIntent(throttle: .2));
      f.step();
      expect(body.state.mass, closeTo(400, .01));
      expect(controller.forceTicks, lessThanOrEqualTo(1));
      final initialForceTicks = controller.forceTicks;
      f.step();
      expect(controller.forceTicks, initialForceTicks + 1);
      expect(f.controller.forceTicks, 2);
      expect(controller.telemetry.groundedWheels, 4);
    },
  );
  test('native suspension settles at load-bearing rest height', () async {
    final f = await VehicleFixture.create();
    addTearDown(f.close);
    f.step(240);
    print(
      'restHeight=${f.body.state.pose.position.y} speed=${f.body.state.velocity.length}',
    );
    expect(f.body.state.pose.position.y, closeTo(.6673, .035));
    expect(f.body.state.velocity.length, lessThan(.1));
    final settledHeight = f.body.state.pose.position.y;
    f.step(120);
    expect(f.body.state.pose.position.y, closeTo(settledHeight, 1e-4));
    expect(f.controller.telemetry.groundedWheels, 4);
    for (final wheel in f.controller.telemetry.wheels) {
      expect(wheel.normalLoad, closeTo(400 * 9.81 / 4, 100));
      expect(wheel.suspensionForce.isFinite, isTrue);
    }
  });

  test(
    'brakes shorten coast distance and reverse changes travel direction',
    () async {
      final coast = await VehicleFixture.create();
      final brake = await VehicleFixture.create();
      addTearDown(coast.close);
      addTearDown(brake.close);
      coast.step(120);
      brake.step(120);
      coast.body.setVelocity(const Vec3(0, 0, 8));
      brake.body.setVelocity(const Vec3(0, 0, 8));
      brake.controller.apply(const VehicleIntent(brake: 1));
      final zCoast = coast.body.state.pose.position.z;
      final zBrake = brake.body.state.pose.position.z;
      coast.step(120);
      brake.step(120);
      print(
        'coastDistance=${coast.body.state.pose.position.z - zCoast} brakeDistance=${brake.body.state.pose.position.z - zBrake} brakeSpeed=${brake.body.state.velocity.length}',
      );
      expect(
        brake.body.state.pose.position.z - zBrake,
        lessThan((coast.body.state.pose.position.z - zCoast) * .5),
      );
      expect(brake.body.state.velocity.length, lessThan(.3));
      brake.controller.apply(const VehicleIntent(throttle: 1, gearRequest: -1));
      brake.step(90);
      print('reverseSpeed=${brake.body.state.velocity.z}');
      expect(brake.body.state.velocity.z, lessThan(-1));
    },
  );

  test(
    'split friction caps combined tire force and airborne tires exert none',
    () async {
      final f = await VehicleFixture.create(splitFriction: true);
      addTearDown(f.close);
      f.step(120);
      f.controller.apply(const VehicleIntent(throttle: 1, steer: .5));
      f.step();
      expect(
        f.controller.telemetry.wheels.any((w) => w.friction == .15),
        isTrue,
      );
      expect(f.controller.telemetry.wheels.any((w) => w.friction == 1), isTrue);
      f.step(29);
      for (final wheel in f.controller.telemetry.wheels) {
        expect(
          wheel.tireForce.length,
          lessThanOrEqualTo(wheel.normalLoad * wheel.friction + 1e-6),
        );
      }
      f.body.teleport(PhysicsPose(position: Vec3(0, 5, 0)));
      f.step();
      expect(f.controller.telemetry.groundedWheels, 0);
      expect(
        f.controller.telemetry.wheels.every((w) => w.tireForce == Vec3.zero),
        isTrue,
      );
    },
  );

  test(
    'rollover reset clears motion and driver deletion applies authored braking',
    () async {
      final f = await VehicleFixture.create();
      addTearDown(f.close);
      final lease = f.controller.acquireControl(f.driver);
      f.controller.apply(const VehicleIntent(throttle: 1), lease: lease);
      f.step(100);
      f.simulation.session.entities.despawn(f.driver);
      f.step();
      expect(lease.isActive, isFalse);
      expect(f.controller.telemetry.appliedIntent.brake, 1);
      expect(
        () =>
            f.controller.apply(const VehicleIntent(throttle: 1), lease: lease),
        throwsStateError,
      );
      f.body.teleport(
        PhysicsPose(
          position: const Vec3(0, 1, 0),
          rotation: Quat.axisAngle(const Vec3(0, 0, 1), 3.14),
        ),
      );
      f.controller.reset(PhysicsPose(position: Vec3(0, .8, 0)));
      f.step(120);
      expect(
        f.body.state.pose.rotation.rotate(const Vec3(0, 1, 0)).y,
        greaterThan(.98),
      );
      expect(f.body.state.velocity.length, lessThan(.1));
    },
  );

  test(
    'possession rejects blocked native exits and competing drivers atomically',
    () async {
      final f = await VehicleFixture.create();
      addTearDown(f.close);
      final possession = GamePossession(f.simulation.session);
      addTearDown(possession.close);
      VehicleControlLease? vehicleLease;
      possession.registerSeat(
        GamePossessionSeat(
          id: 'driver',
          target: f.actor,
          canReach: (actor) =>
              f.driverBodies[actor]!.state.pose.position.distanceTo(
                f.body.state.pose.position,
              ) <
              3,
          canExit: (actor) => f.world
              .overlap(
                shape: const SphereShape(.25),
                pose: PhysicsPose(
                  position: f.body.state.pose.position + const Vec3(1.4, .6, 0),
                ),
                filter: QueryFilter(excludeBody: f.body, excludeSensors: true),
              )
              .isEmpty,
          acquireControl: (actor) {
            final lease = vehicleLease = f.controller.acquireControl(actor);
            return GamePossessionControl(
              isActive: () => lease.isActive,
              release: lease.dispose,
            );
          },
        ),
      );
      expect(possession.transfer(f.driver, 'driver'), isTrue);
      final occupant = possession.occupant('driver');
      expect(possession.transfer(f.otherDriver, 'driver'), isFalse);
      expect(possession.occupant('driver'), occupant);
      final obstacle = f.world.createBody(
        kind: BodyKind.fixed,
        pose: PhysicsPose(
          position: f.body.state.pose.position + const Vec3(1.4, .6, 0),
        ),
      );
      obstacle.addCollider(const BoxShape(Vec3(.4, .4, .4)));
      expect(possession.transfer(f.driver, null), isFalse);
      expect(vehicleLease!.isActive, isTrue);
      obstacle.remove();
      expect(possession.transfer(f.driver, null), isTrue);
      expect(vehicleLease!.isActive, isFalse);
    },
  );

  test(
    'character to vehicle possession releases the old motor producer',
    () async {
      final f = await GameCharacterFixture.create();
      addTearDown(f.close);
      final session = f.simulation.session;
      final target = session.entities.spawn('vehicle');
      final chassis = f.world.createBody(
        pose: PhysicsPose(position: const Vec3(2, .8, 0)),
        mass: 400,
        inertia: const Vec3(200, 277, 94),
      );
      chassis.addCollider(const BoxShape(Vec3(.8, .25, 1.2)), density: 0);
      final vehicle = VehicleController(
        session: session,
        actor: target,
        body: chassis,
        definition: buggyDefinition(),
      );
      final host = GamePossession(session);
      addTearDown(host.close);
      GameCharacterControlLease? characterLease;
      VehicleControlLease? vehicleLease;
      host.registerSeat(
        GamePossessionSeat(
          id: 'on-foot',
          target: f.controller.actor,
          canReach: (_) => true,
          canExit: (_) => true,
          acquireControl: (_) {
            final lease = characterLease = f.controller.acquireControl();
            return GamePossessionControl(
              isActive: () => lease.isActive,
              release: lease.dispose,
            );
          },
        ),
      );
      host.registerSeat(
        GamePossessionSeat(
          id: 'vehicle',
          target: target,
          canReach: (_) =>
              f.body.state.pose.position.distanceTo(
                chassis.state.pose.position,
              ) <
              3,
          canExit: (_) => true,
          acquireControl: (actor) {
            final lease = vehicleLease = vehicle.acquireControl(actor);
            return GamePossessionControl(
              isActive: () => lease.isActive,
              release: lease.dispose,
            );
          },
        ),
      );
      expect(host.transfer(f.controller.actor, 'on-foot'), isTrue);
      f.controller.apply(
        const CharacterIntent(moveX: 1),
        lease: characterLease,
      );
      expect(host.transfer(f.controller.actor, 'vehicle'), isTrue);
      expect(characterLease!.isActive, isFalse);
      expect(vehicleLease!.isActive, isTrue);
      expect(
        () => f.controller.apply(
          const CharacterIntent(moveX: 1),
          lease: characterLease,
        ),
        throwsStateError,
      );
      for (var i = 0; i < 10; i++) {
        f.simulation.step();
      }
      expect(f.body.state.pose.position.x, closeTo(0, 1e-5));
    },
  );
  test('slope and obstacle maintain finite chassis and contact state', () async {
    final f = await VehicleFixture.create(slope: .12, obstacle: true);
    addTearDown(f.close);
    f.step(120);
    f.controller.apply(const VehicleIntent(throttle: .4));
    f.step(240);
    print(
      'slopeObstaclePose=${f.body.state.pose.position} velocity=${f.body.state.velocity}',
    );
    expect(f.body.state.pose.position.isFinite, isTrue);
    expect(f.body.state.pose.rotation.isFinite, isTrue);
    expect(f.body.state.pose.position.y, greaterThan(.1));
    expect(f.body.state.pose.position.z, closeTo(2.4, .2));
    expect(
      Vec3(f.body.state.velocity.x, 0, f.body.state.velocity.z).length,
      lessThan(.1),
    );
    expect(
      f.controller.telemetry.wheels.every((w) => w.suspensionForce.isFinite),
      isTrue,
    );
  });

  test(
    '30 60 120 Hz presentations preserve one fixed physics trajectory',
    () async {
      final positions = <Vec3>[];
      for (final hz in [30, 60, 120]) {
        final f = await VehicleFixture.create();
        f.controller.apply(const VehicleIntent(throttle: .5));
        for (var frame = 0; frame < hz * 2; frame++) {
          f.simulation.advance(1 / hz);
          await f.render(1 / hz);
        }
        positions.add(f.body.state.pose.position);
        expect(f.controller.forceTicks, 120);
        expect(f.wheelVisuals.any((wheel) => wheel.position.y != 0), isTrue);
        await f.close();
      }
      print('presentationPositions=$positions');
      for (final p in positions.skip(1)) {
        expect(p.distanceTo(positions.first), lessThan(1e-6));
      }
    },
  );
}
