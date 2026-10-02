import 'package:zyren/zyren.dart';
import 'package:zyren_characters/zyren_characters.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'package:zyren_navigation/zyren_navigation.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import 'character_asset.dart';

/// Explicit fixed-step host for an imported robot and a native kinematic capsule.
/// The route is authored for an empty floor. Collision avoidance is not provided.
final class WalkthroughScene {
  final AssetScope assets;
  final ModelInstance model;
  final scene = Scene();
  final root = Group(name: 'Character physics root');
  final PhysicsWorld world;
  late final PhysicsPlugin physics;
  late final PhysicsBody body;
  late final SceneTimelinePlugin timeline;
  late final CharacterAnimationPlugin character;
  late final NavigationMesh navigation;
  late final NavigationPath route;
  double distance = 0;
  bool _closed = false;
  static const step = Duration(milliseconds: 20);
  static const speed = .8;
  static const offset = Vec3(0, .7, 0);

  static Future<WalkthroughScene> load() async {
    final assets = AssetScope(
      services: AssetServices(resolver: CharacterAssetSource()),
    );
    PhysicsWorld? world;
    try {
      final asset = await assets.load(Gltf.asset('character.gltf')).result;
      world = PhysicsWorld(fixedStep: .02);
      return WalkthroughScene._(assets, asset.instantiate(), world);
    } catch (_) {
      world?.close();
      await assets.close();
      rethrow;
    }
  }

  WalkthroughScene._(this.assets, this.model, this.world) {
    navigation = NavigationMesh(
      vertices: const [
        Vec3(0, 0, 0),
        Vec3(1, 0, 0),
        Vec3(2, 0, 0),
        Vec3(0, 0, 1),
        Vec3(1, 0, 1),
        Vec3(2, 0, 1),
        Vec3(0, 0, 2),
        Vec3(1, 0, 2),
      ],
      triangles: const [
        [0, 1, 4],
        [0, 4, 3],
        [1, 2, 5],
        [1, 5, 4],
        [3, 4, 7],
        [3, 7, 6],
      ],
    );
    route = navigation.findPath(const Vec3(1.8, 0, .2), const Vec3(.2, 0, 1.8));
    scene.add(root);
    root.add(model);
    body = world.createBody(
      kind: BodyKind.kinematicPosition,
      pose: PhysicsPose(position: route.points.first + offset),
    );
    body.addCollider(const CapsuleShape(halfHeight: .45, radius: .25));
    physics = PhysicsPlugin(world: world, interpolate: false)..bind(root, body);
    timeline = SceneTimelinePlugin.mixed(
      duration: const Duration(seconds: 1),
      base: modelRestClip(model),
    );
    character = CharacterAnimationPlugin(
      timeline: timeline,
      states: [
        CharacterState.rest('idle', model),
        CharacterState.animation('walk', model, model.animations.single),
      ],
      transitions: [
        CharacterTransition('idle', 'walk'),
        CharacterTransition('walk', 'idle'),
      ],
      initialState: 'idle',
    );
    for (final (x, z) in [(0.5, 0.5), (1.5, 0.5), (0.5, 1.5)]) {
      scene.add(
        Mesh(
          BoxGeometry(width: 1, height: .04, depth: 1),
          UnlitMaterial(color: const Color3(.15, .19, .23)),
        )..position = Vec3(x, -.02, z),
      );
    }
  }
  bool get arrived => distance >= route.length;

  /// Call once, then render with [step] as the explicit timeline delta.
  /// Physics stays outside engine.plugins to prevent a second simulation driver.
  void advance() {
    if (_closed) throw StateError('Walkthrough has closed.');
    if (!arrived) {
      if (character.currentState != 'walk') character.transitionTo('walk');
      distance = (distance + speed * world.fixedStep).clamp(0, route.length);
      body.setTarget(PhysicsPose(position: route.pointAt(distance) + offset));
    }
    physics.advance(world.fixedStep);
    if (arrived && character.currentState != 'idle') {
      character.transitionTo('idle');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    physics.clearBindings();
    world.close();
    await assets.close();
  }
}
