import 'package:zyren/zyren.dart';
import 'package:zyren_characters/zyren_characters.dart';
import 'package:zyren_characters/physics.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import 'native_game_fixture.dart';
import '../../../../examples/game_lab/assets/skinned_character_asset.dart';

final class GameCharacterFixture {
  final AssetScope assets;
  final ModelInstance model;
  final scene = Scene();
  final actorObject = Group();
  final world = PhysicsWorld(fixedStep: .02);
  late final GameSimulation simulation;
  late final GameCharacterMotorRegistry motors;
  late final PhysicsPlugin physics;
  late final PhysicsBody body;
  late final CharacterMotor motor;
  late final CharacterAnimationPlugin animation;
  late final SceneTimelinePlugin timeline;
  late final GameCharacterController controller;
  late final SceneEngine engine;
  late final Registration connection, registration;
  int motorSteps = 0, ikSamples = 0;
  static Future<GameCharacterFixture> create({
    Vec3 position = const Vec3(0, .81, 0),
    double maxSpeed = 2,
    bool floor = true,
    List<GameSystem> systems = const [],
  }) async {
    final assets = AssetScope(
      services: AssetServices(resolver: SkinnedCharacterSource()),
    );
    try {
      final source = await assets.load(Gltf.asset('skin.gltf')).result;
      final fixture = GameCharacterFixture._(
        assets,
        source.instantiate(nativeDeformation: false),
        position,
        maxSpeed,
        floor,
        systems,
      );
      fixture.engine = await SceneEngine.create(
        scene: fixture.scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => FixtureRenderer(),
        plugins: [fixture.timeline, fixture.animation, fixture.physics],
      );
      fixture.simulation.step();
      final actor = fixture.simulation.session.entities.spawn('actor');
      fixture.controller = GameCharacterController(
        actor: actor,
        session: fixture.simulation.session,
        motor: fixture.motor,
        definition: GameCharacterDefinition(maxSpeed: maxSpeed),
      );
      fixture.registration = fixture.motors.register(
        fixture.controller,
        fixture.actorObject,
      );
      return fixture;
    } catch (_) {
      await assets.close();
      rethrow;
    }
  }

  GameCharacterFixture._(
    this.assets,
    this.model,
    Vec3 position,
    double maxSpeed,
    bool floor,
    List<GameSystem> systems,
  ) {
    scene.add(actorObject);
    actorObject.add(model);
    model.position = const Vec3(0, -.8, 0);
    if (floor) box(const Vec3(0, -.5, 0), const Vec3(20, .5, 20));
    body = world.createBody(
      kind: BodyKind.kinematicPosition,
      pose: PhysicsPose(position: position),
    );
    final capsule = body.addCollider(
      const CapsuleShape(halfHeight: .5, radius: .3),
    );
    final root = RootMotion(model, root: 0);
    final rig = CharacterRig(
      model,
      joints: {
        'root': 0,
        'leftHip': 1,
        'leftKnee': 2,
        'leftFoot': 3,
        'rightHip': 4,
        'rightKnee': 5,
        'rightFoot': 6,
        'spine': 7,
        'head': 8,
      },
    );
    final ik = TwoBoneIk(rig, upper: 1, lower: 2, end: 3);
    ModelPose process(ModelPose pose) {
      ikSamples++;
      return ik
          .solve(
            root.strip(pose),
            target: const Vec3(-.16, .08, .04),
            pole: const Vec3(-.16, .5, 1),
            weight: .8,
          )
          .pose;
    }

    timeline = SceneTimelinePlugin.mixed(
      duration: const Duration(seconds: 1),
      base: modelRestClip(model, process: process),
    )..externallyDriven = true;
    animation = CharacterAnimationPlugin(
      timeline: timeline,
      states: [
        CharacterState.rest('idle', model, process: process),
        CharacterState.animation(
          'walk',
          model,
          model.animations.single,
          process: process,
        ),
      ],
      transitions: [
        CharacterTransition('idle', 'walk'),
        CharacterTransition('walk', 'idle'),
      ],
      initialState: 'walk',
    );
    motor = CharacterMotor(
      character: animation,
      rootMotion: root,
      controller: KinematicCharacterController(body: body, collider: capsule),
    );
    motors = GameCharacterMotorRegistry(world);
    physics = PhysicsPlugin(
      world: world,
      externallyDriven: true,
      interpolate: false,
      beforeStep: motors.advance,
    );
    simulation = GameSimulation(
      project: testProject(fixedHz: 50),
      seed: 3,
      physics: physics,
      systems: systems,
    );
    connection = motors.connect(simulation);
  }
  PhysicsBody box(
    Vec3 center,
    Vec3 half, {
    BodyKind kind = BodyKind.fixed,
    Quat rotation = Quat.identity,
  }) {
    final body = world.createBody(
      kind: kind,
      pose: PhysicsPose(position: center, rotation: rotation),
    );
    body.addCollider(BoxShape(half));
    return body;
  }

  void step([int count = 1]) {
    for (var i = 0; i < count; i++) {
      simulation.step();
      motorSteps++;
    }
  }

  Future<void> close() async {
    registration.dispose();
    connection.dispose();
    await engine.dispose();
    await simulation.close();
    world.close();
    await assets.close();
  }
}
