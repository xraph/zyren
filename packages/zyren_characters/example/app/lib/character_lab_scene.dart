import 'package:zyren/zyren.dart';
import 'package:zyren_characters/zyren_characters.dart';
import 'package:zyren_characters/physics.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'package:zyren_navigation/zyren_navigation.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import 'skinned_character_asset.dart';

final class CharacterLabScene {
  final AssetScope assets;
  final ModelInstance model, retargeted;
  final scene = Scene()..background = const Color3(.055, .07, .09);
  final actor = Group(name: 'Character');
  final world = PhysicsWorld(fixedStep: .02);
  late final PhysicsBody body, crateBody;
  late final PhysicsCollider crateCollider;
  late final Mesh crate, floor;
  late final NavigationWorld navigation;
  late final NavigationFollower follower;
  late final CharacterRig rig;
  late final RigRetargeter retargeter;
  late final RootMotion rootMotion;
  late final SceneTimelinePlugin timeline;
  late final CharacterAnimationPlugin character;
  late final PhysicsPlugin physics;
  late final CharacterMotor motor;
  late final TwoBoneIk leftFoot, rightFoot;
  late final LookAtIk head;
  late final ModelPose Function(ModelPose) process = _process;
  ModelPose? _lastPose;
  Vec3 lookTarget = const Vec3(0, 1.5, 3);
  final footTargets = <int, Vec3>{};
  bool obstacle = false,
      ikEnabled = true,
      retargetEnabled = true,
      removed = false;
  int steps = 0, revision = 0;
  ViewportMetrics viewport = const ViewportMetrics(1, 1);
  static const step = Duration(milliseconds: 20);
  static const goal = Vec3(5, 0, 5);
  static const modelOffset = Vec3(0, -.8, 0);
  static Future<CharacterLabScene> load({bool nativeDeformation = true}) async {
    final assets = AssetScope(
      services: AssetServices(resolver: SkinnedCharacterSource()),
    );
    try {
      final source = await assets.load(Gltf.asset('skin.gltf')).result;
      final tall = await assets.load(Gltf.asset('tall.gltf')).result;
      return CharacterLabScene._(
        assets,
        source.instantiate(nativeDeformation: nativeDeformation),
        tall.instantiate(nativeDeformation: nativeDeformation),
      );
    } catch (_) {
      await assets.close();
      rethrow;
    }
  }

  CharacterLabScene._(this.assets, this.model, this.retargeted) {
    floor = Mesh(
      BoxGeometry(width: 6, height: .2, depth: 6),
      UnlitMaterial(color: const Color3(.14, .19, .23)),
    )..position = const Vec3(3, -.1, 3);
    scene.add(floor);
    scene.add(actor);
    actor.add(model);
    model.position = modelOffset;
    scene.add(retargeted);
    retargeted.position = const Vec3(5, 0, 1);
    final floorBody = world.createBody(
      kind: BodyKind.fixed,
      pose: PhysicsPose(position: floor.position),
    );
    floorBody.addCollider(const BoxShape(Vec3(3, .1, 3)));
    body = world.createBody(
      kind: BodyKind.kinematicPosition,
      pose: PhysicsPose(position: const Vec3(1, .81, 1)),
    );
    final capsule = body.addCollider(
      const CapsuleShape(halfHeight: .5, radius: .3),
    );
    crate =
        Mesh(
            BoxGeometry(width: .8, height: 1.1, depth: .8),
            UnlitMaterial(color: const Color3(.9, .42, .16)),
          )
          ..position = const Vec3(3, .55, 3)
          ..visible = false;
    scene.add(crate);
    crateBody = world.createBody(
      kind: BodyKind.fixed,
      pose: PhysicsPose(position: crate.position),
    );
    crateCollider = crateBody.addCollider(
      const BoxShape(Vec3(.4, .55, .4)),
      sensor: true,
    );
    navigation = NavigationWorld(_bake());
    follower = NavigationFollower(navigation)..setGoal(goal);
    final joints = {
      'root': 0,
      'leftHip': 1,
      'leftKnee': 2,
      'leftFoot': 3,
      'rightHip': 4,
      'rightKnee': 5,
      'rightFoot': 6,
      'spine': 7,
      'head': 8,
    };
    rig = CharacterRig(model, joints: joints);
    retargeter = RigRetargeter(
      source: rig,
      target: CharacterRig(retargeted, joints: joints),
      sourceRoot: 0,
      targetRoot: 0,
      mapping: {for (final id in joints.values) id: id},
    );
    leftFoot = TwoBoneIk(rig, upper: 1, lower: 2, end: 3);
    rightFoot = TwoBoneIk(rig, upper: 4, lower: 5, end: 6);
    head = LookAtIk(rig, joint: 8, maxAngle: .6);
    rootMotion = RootMotion(model, root: 0);
    timeline = SceneTimelinePlugin.mixed(
      duration: const Duration(seconds: 1),
      base: modelRestClip(model, process: process),
    )..externallyDriven = true;
    character = CharacterAnimationPlugin(
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
      character: character,
      rootMotion: rootMotion,
      controller: KinematicCharacterController(body: body, collider: capsule),
    );
    physics = PhysicsPlugin(
      world: world,
      interpolate: false,
      beforeStep: (_) => advanceCharacter(),
    );
    physics.bind(actor, body);
  }
  BakedNavigationMesh _bake() =>
      NavigationBaker(
        settings: NavigationBakeSettings(
          cellSize: .25,
          radius: .3,
          height: 1.8,
        ),
      ).bake([
        NavigationGeometry.fromMesh(
          floor,
          sourceId: 'lab-floor',
          revision: '1',
        ),
      ]);
  List<ScenePlugin> get plugins => [timeline, character, physics];
  Vec3 get feet {
    final p = body.state.pose.position;
    return Vec3(p.x, 0, p.z);
  }

  bool get arrived => feet.distanceTo(follower.goal ?? feet) < .06;
  void rebuildNavigation() {
    navigation.replaceMesh(_bake());
    revision++;
  }

  void setGoal(Vec3 goal) {
    follower.setGoal(goal);
    if (character.isAttached &&
        !character.isPaused &&
        character.currentState != 'walk') {
      character.transitionTo('walk');
    }
    revision++;
  }

  void setObstacle(bool value) {
    obstacle = value;
    crate.visible = value;
    crateCollider.configure(sensor: !value);
    navigation.setObstacles(
      value
          ? [
              NavigationObstacle(
                'crate',
                min: const Vec3(2.6, 0, 2.6),
                max: const Vec3(3.4, 1.1, 3.4),
              ),
            ]
          : [],
    );
    revision++;
  }

  void setPaused(bool value) {
    physics.paused = value;
    if (value) {
      character.pause();
    } else {
      character.resume();
    }
    revision++;
  }

  void advanceCharacter() {
    if (removed || !character.isAttached) return;
    motor.advance(step, steer: (distance) => follower.intent(feet, distance));
    if (arrived && character.currentState == 'walk') {
      character.transitionTo('idle');
    }
    if (retargetEnabled && _lastPose != null) {
      retargeted.prepareSampledPose(retargeter.apply(_lastPose!))();
    }
    steps++;
    revision++;
  }

  ModelPose _process(ModelPose input) {
    var pose = rootMotion.strip(input);
    if (ikEnabled) {
      for (final solver in [leftFoot, rightFoot]) {
        final local = rig.world(pose)[solver.end]!.position;
        final bodyPose = body.state.pose;
        final point =
            bodyPose.position + bodyPose.rotation.rotate(local + modelOffset);
        final hit = world.rayCast(
          origin: point + const Vec3(0, .5, 0),
          direction: const Vec3(0, -1, 0),
          maxDistance: 1,
          filter: QueryFilter(excludeBody: body, excludeSensors: true),
        );
        final explicit = footTargets[solver.end];
        if (explicit != null || hit != null && hit.normal.y > .7) {
          final ground = point + Vec3(0, .55 - (hit?.time ?? 0), 0);
          final target =
              explicit ??
              inverseRotation(
                    bodyPose.rotation,
                  ).rotate(ground - bodyPose.position) -
                  modelOffset;
          pose = solver
              .solve(
                pose,
                target: target,
                pole: local + const Vec3(0, .5, 1),
                weight: .8,
              )
              .pose;
        }
      }
      pose = head.solve(pose, lookTarget, weight: .6);
    }
    _lastPose = pose;
    return pose;
  }

  void removeCharacter() {
    if (removed) return;
    physics.removeBody(actor);
    scene.remove(actor);
    removed = true;
    revision++;
  }

  Future<void> close() async {
    world.close();
    await assets.close();
  }
}
