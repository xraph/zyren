import 'dart:convert';
import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'native_game_fixture.dart';

VehicleDefinition buggyDefinition() => VehicleDefinition.fromJson(
  jsonDecode(
        File(
          '../../examples/game_lab/assets/vehicles/buggy.json',
        ).readAsStringSync(),
      )
      as Map<String, Object?>,
);

class VehicleFixture {
  final PhysicsWorld world;
  final PhysicsBody body;
  final GameSimulation simulation;
  final VehicleController controller;
  final GameEntityHandle actor, driver, otherDriver;
  final Map<GameEntityHandle, PhysicsBody> driverBodies;
  final SceneEngine engine;
  final List<Object3D> wheelVisuals;
  final GameVehicleSystem vehicles;
  final Scene scene;
  VehicleFixture._(
    this.world,
    this.body,
    this.simulation,
    this.controller,
    this.actor,
    this.driver,
    this.otherDriver,
    this.driverBodies,
    this.engine,
    this.wheelVisuals,
    this.vehicles,
    this.scene,
  );
  static Future<VehicleFixture> create({
    bool splitFriction = false,
    double slope = 0,
    bool obstacle = false,
  }) async {
    final world = PhysicsWorld(fixedStep: 1 / 60);
    final ground = world.createBody(
      kind: BodyKind.fixed,
      pose: PhysicsPose(
        position: const Vec3(0, -.1, 0),
        rotation: Quat.axisAngle(const Vec3(1, 0, 0), slope),
      ),
    );
    ground.addCollider(const BoxShape(Vec3(100, .1, 100)));
    if (obstacle) {
      world
          .createBody(
            kind: BodyKind.fixed,
            pose: PhysicsPose(position: Vec3(0, .15, 4)),
          )
          .addCollider(const BoxShape(Vec3(1, .15, .4)));
    }
    final body = world.createBody(
      pose: PhysicsPose(position: Vec3(0, .8, 0)),
      mass: 400,
      inertia: const Vec3(200, 277, 94),
      canSleep: false,
      linearDamping: .01,
      angularDamping: .15,
      ccd: true,
    );
    body.addCollider(const BoxShape(Vec3(.8, .25, 1.2)), density: 0);
    final physics = PhysicsPlugin(
      world: world,
      externallyDriven: true,
      interpolate: false,
    );
    final vehicles = GameVehicleSystem(world: world, physics: physics);
    final simulation = GameSimulation(
      project: testProject(),
      seed: 3,
      physics: physics,
      systems: [vehicles, GameVehiclePresentationSystem(vehicles)],
    );
    simulation.step();
    final actor = simulation.session.entities.spawn('buggy');
    final driver = simulation.session.entities.spawn('driver');
    final otherDriver = simulation.session.entities.spawn('other-driver');
    final driverBodies = <GameEntityHandle, PhysicsBody>{};
    for (final handle in [driver, otherDriver]) {
      final driverBody = world.createBody(
        kind: BodyKind.fixed,
        pose: PhysicsPose(position: Vec3(2, 1, 0)),
      );
      driverBody.addCollider(const SphereShape(.1), sensor: true);
      driverBodies[handle] = driverBody;
    }
    final controller = VehicleController(
      session: simulation.session,
      actor: actor,
      body: body,
      definition: buggyDefinition(),
      surfaceFriction: (hit, point) => splitFriction && point.x < 0 ? .15 : 1,
    );
    final scene = Scene();
    final root = scene.add(Group());
    final wheelVisuals = [for (var i = 0; i < 4; i++) root.add(Group())];
    vehicles.register(
      controller,
      presentationRoot: root,
      wheelVisuals: wheelVisuals,
    );
    final engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(),
      rendererFactory: () async => FixtureRenderer(),
      plugins: [physics],
    );
    return VehicleFixture._(
      world,
      body,
      simulation,
      controller,
      actor,
      driver,
      otherDriver,
      driverBodies,
      engine,
      wheelVisuals,
      vehicles,
      scene,
    );
  }

  void step([int count = 1]) {
    for (var i = 0; i < count; i++) {
      simulation.step();
    }
  }

  Future<void> render(double seconds) async {
    await engine.render(
      elapsed: Duration(microseconds: (seconds * 1e6).round()),
      width: 8,
      height: 8,
    );
  }

  Future<void> close() async {
    await engine.dispose();
    await simulation.close();
    world.close();
  }
}
