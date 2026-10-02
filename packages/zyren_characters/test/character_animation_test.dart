import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_characters/zyren_characters.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import '../example/character_asset.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  late AssetScope scope;
  late ModelInstance model;
  late Scene scene;
  late SceneEngine engine;
  late CharacterAnimationPlugin character;
  var demands = 0;
  setUp(() async {
    demands = 0;
    scope = AssetScope(
      services: AssetServices(resolver: CharacterAssetSource()),
    );
    final asset = await scope.load(Gltf.asset('character.gltf')).result;
    model = asset.instantiate();
    scene = Scene()..add(model);
    final timeline = SceneTimelinePlugin.mixed(
      duration: const Duration(seconds: 1),
      base: modelRestClip(model),
    );
    character = CharacterAnimationPlugin(
      timeline: timeline,
      states: [
        CharacterState.rest('idle', model),
        CharacterState.animation('walk', model, model.animations.single),
        CharacterState.rest('halt', model),
      ],
      transitions: [
        CharacterTransition('idle', 'walk'),
        CharacterTransition('walk', 'idle'),
        CharacterTransition('walk', 'halt'),
        CharacterTransition('halt', 'walk'),
      ],
      initialState: 'idle',
    );
    engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(),
      rendererFactory: () async => TestRenderer([]),
      plugins: [character, timeline],
      acquireFrameDemand: () {
        demands++;
        return Registration(() => demands--);
      },
    );
  });
  tearDown(() async {
    await engine.dispose();
    await scope.close();
  });
  Future<void> tick(int ms) => engine.render(
    elapsed: Duration.zero,
    time: FrameTime(delta: Duration(milliseconds: ms)),
    width: 8,
    height: 8,
  );

  test(
    'real imported walk clip fades, moves hips and keeps the instance root',
    () async {
      expect(character.transitionTo('walk'), isTrue);
      await tick(0);
      await tick(100);
      expect(character.weights['walk'], closeTo(.5, 1e-9));
      expect(model.nodes[3]!.quaternion.x, greaterThan(0));
      expect(model.nodes[5]!.quaternion.x, lessThan(0));
      expect(model.position, Vec3.zero);
      await tick(100);
      expect(character.weights, {'idle': 0, 'walk': 1, 'halt': 0});
      expect(character.positionOf('walk'), const Duration(milliseconds: 200));
      expect(character.transitionTo('walk'), isFalse);
    },
  );
  test(
    'interrupted three-state transition fades every previous contributor',
    () async {
      character.transitionTo('walk');
      await tick(0);
      await tick(100);
      character.transitionTo('halt');
      await tick(100);
      expect(character.weights['idle'], closeTo(.25, 1e-9));
      expect(character.weights['walk'], closeTo(.25, 1e-9));
      expect(character.weights['halt'], closeTo(.5, 1e-9));
      await tick(100);
      await tick(1000);
      expect(character.weights, {'idle': 0, 'walk': 0, 'halt': 1});
      expect(demands, 0);
    },
  );
  test(
    'invalid edges are inert and pause releases all character demand',
    () async {
      final before = character.weights;
      expect(() => character.transitionTo('halt'), throwsStateError);
      expect(character.weights, before);
      character.transitionTo('walk');
      await tick(0);
      await tick(100);
      character.pause();
      final position = character.positionOf('walk');
      expect(demands, 0);
      await tick(500);
      expect(character.positionOf('walk'), position);
      expect(() => character.transitionTo('idle'), throwsStateError);
      character.resume();
      await tick(0);
      await tick(200);
      expect(character.weights['walk'], 1);
    },
  );
  test('removed targets fail and detach releases demand and handles', () async {
    character.transitionTo('walk');
    await tick(0);
    scene.remove(model);
    await expectLater(tick(100), throwsStateError);
    expect(demands, 0);
    await engine.dispose();
    expect(() => character.transitionTo('idle'), throwsStateError);
    expect(character.weights, isEmpty);
  });
  test('engine disposal releases a looping character', () async {
    character.transitionTo('walk');
    await tick(0);
    await tick(300);
    expect(demands, 1);
    await engine.dispose();
    expect(demands, 0);
  });
}
