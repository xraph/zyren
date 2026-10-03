import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_characters/zyren_characters.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
// Keep the example fixture outside the package dependency graph.
// ignore: avoid_relative_lib_imports
import '../example/app/lib/skinned_character_asset.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  late AssetScope assets;
  late ModelInstance model, tall;
  CharacterRig rig(ModelInstance instance) => CharacterRig(
    instance,
    joints: {'root': 0, 'hip': 1, 'knee': 2, 'foot': 3, 'spine': 7, 'head': 8},
  );
  setUp(() async {
    assets = AssetScope(
      services: AssetServices(resolver: SkinnedCharacterSource()),
    );
    model = (await assets.load(Gltf.asset('skin.gltf')).result).instantiate(
      nativeDeformation: false,
    );
    tall = (await assets.load(Gltf.asset('tall.gltf')).result).instantiate(
      nativeDeformation: false,
    );
  });
  tearDown(() => assets.close());
  test('root yaw retains a full authored turn across loop crossings', () async {
    final turning = (await assets.load(Gltf.asset('turn.gltf')).result)
        .instantiate(nativeDeformation: false);
    final root = RootMotion(turning, root: 0);
    final value = root.sample(
      turning.animations.single,
      const Duration(milliseconds: 900),
      const Duration(milliseconds: 2300),
    );
    expect(value.yaw, closeTo(2.3 * 2 * math.pi, 1e-6));
  });
  test('root travel covers forward and reverse multi-loop crossings', () {
    final root = RootMotion(model, root: 0),
        animation = model.animations.single;
    expect(
      root
          .sample(
            animation,
            const Duration(milliseconds: 900),
            const Duration(milliseconds: 2300),
          )
          .translation
          .z,
      closeTo(2.3, 1e-6),
    );
    expect(
      root
          .sample(
            animation,
            const Duration(milliseconds: 100),
            const Duration(milliseconds: -2300),
          )
          .translation
          .z,
      closeTo(-2.3, 1e-6),
    );
    final pose = root.strip(
      model.samplePose(
        initial: true,
        animation: animation,
        time: const Duration(milliseconds: 500),
      ),
    );
    expect(pose.nodes[0]!.position, Vec3.zero);
    model.prepareSampledPose(pose)();
  });
  test(
    'external clock advances once per step, strips skin root and freezes on pause',
    () async {
      final root = RootMotion(model, root: 0);
      final timeline = SceneTimelinePlugin.mixed(
        duration: const Duration(seconds: 1),
        base: modelRestClip(model, process: root.process),
      )..externallyDriven = true;
      final character = CharacterAnimationPlugin(
        timeline: timeline,
        states: [
          CharacterState.animation(
            'walk',
            model,
            model.animations.single,
            process: root.process,
          ),
        ],
        transitions: [],
        initialState: 'walk',
      );
      final engine = await SceneEngine.create(
        scene: Scene()..add(model),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [timeline, character],
      );
      try {
        var distance = 0.0;
        for (var i = 0; i < 120; i++) {
          distance += root
              .advance(character, const Duration(milliseconds: 20))
              .translation
              .z;
          await engine.render(
            elapsed: Duration.zero,
            time: const FrameTime(delta: Duration(milliseconds: 40)),
            width: 8,
            height: 8,
          );
        }
        expect(distance, closeTo(2.4, 1e-6));
        expect(model.nodes[0]!.position, Vec3.zero);
        character.pause();
        expect(
          root.advance(character, const Duration(milliseconds: 20)).translation,
          Vec3.zero,
        );
      } finally {
        await engine.dispose();
      }
    },
  );
  test(
    'two-bone solve reaches target, respects limits and handles pole singularity',
    () {
      final skeleton = rig(model), pose = model.samplePose(initial: true);
      final ik = TwoBoneIk(skeleton, upper: 1, lower: 2, end: 3);
      final target = const Vec3(-.16, .3, .3);
      final result = ik.solve(
        pose,
        target: target,
        pole: const Vec3(-.16, .7, 1),
      );
      expect(result.error, lessThan(1e-8));
      expect(result.limited, isFalse);
      expect(pose.nodes[1]!.rotation, Quat.identity);
      model.prepareSampledPose(result.pose)();
      final far = ik.solve(
        pose,
        target: const Vec3(0, -10, 0),
        pole: const Vec3(-.16, .95, 0),
      );
      expect(far.limited, isTrue);
      expect(far.error, greaterThan(9));
      expect(skeleton.world(far.pose)[3]!.position.isFinite, isTrue);
    },
  );
  test('look-at clamps angular reach', () {
    final skeleton = rig(model), pose = model.samplePose(initial: true);
    final out = LookAtIk(
      skeleton,
      joint: 8,
      maxAngle: math.pi / 6,
    ).solve(pose, const Vec3(10, 1.6, 0));
    final direction = skeleton
        .world(out)[8]!
        .rotation
        .rotate(const Vec3(0, 0, 1));
    expect(math.acos(direction.z), closeTo(math.pi / 6, 1e-8));
  });
  test(
    'retarget preserves target proportions and binds, with explicit axis correction',
    () {
      final from = rig(model), to = rig(tall);
      final retarget = RigRetargeter(
        source: from,
        target: to,
        sourceRoot: 0,
        targetRoot: 0,
        mapping: {0: 0, 1: 1, 2: 2, 3: 3, 7: 7, 8: 8},
      );
      final bind = retarget.apply(from.bindPose);
      expect(bind.nodes[2]!.position, to.bindPose.nodes[2]!.position);
      final animated = model.samplePose(
        initial: true,
        animation: model.animations.single,
        time: const Duration(milliseconds: 250),
      );
      final out = retarget.apply(animated);
      expect(
        out.nodes[1]!.rotation.x,
        closeTo(animated.nodes[1]!.rotation.x, 1e-8),
      );
      expect(out.nodes[0]!.position.z, closeTo(.25, 1e-8));
      expect(
        to.world(out)[2]!.position.distanceTo(to.world(out)[1]!.position),
        closeTo(.585, 1e-8),
      );
      tall.prepareSampledPose(out)();
      final foot = to.world(out)[3]!.position;
      final leg = TwoBoneIk(to, upper: 1, lower: 2, end: 3);
      final tooLow = leg.solve(
        out,
        target: Vec3(foot.x, .05, foot.z),
        pole: const Vec3(-.16, .7, 1),
      );
      expect(tooLow.limited, isTrue);
      expect(tooLow.error, greaterThan(.01));
      final contact = Vec3(foot.x, .1, to.world(out)[1]!.position.z + .1);
      final placed = leg.solve(
        out,
        target: contact,
        pole: const Vec3(-.16, .7, 1),
      );
      expect(placed.error, lessThan(1e-8));
      expect(to.world(placed.pose)[3]!.position.y, closeTo(.1, 1e-8));
      expect(placed.pose.nodes[2]!.position, to.bindPose.nodes[2]!.position);
      final corrected = RigRetargeter(
        source: from,
        target: to,
        sourceRoot: 0,
        targetRoot: 0,
        mapping: {0: 0, 1: 1},
        axisCorrections: {1: Quat.axisAngle(const Vec3(0, 1, 0), math.pi / 2)},
      ).apply(animated);
      expect(corrected.nodes[1]!.rotation.z.abs(), greaterThan(.1));
    },
  );
  test('pose edits reject foreign IDs and preserve template ownership', () {
    final pose = model.samplePose(initial: true);
    expect(() => pose.withNodes({99: pose.nodes[0]!}), throwsArgumentError);
    expect(() => tall.prepareSampledPose(pose), throwsArgumentError);
    expect(() => rig(tall).world(pose), throwsArgumentError);
  });
}
