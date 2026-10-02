import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';
import 'deformation_checks.dart' show skinBox, deformedReference;

Future<void> verifyAnimationTransitions(NativeGpuBackend backend) async {
  final geometry = skinBox(), material = StandardMaterial(roughness: .8);
  final scene = Scene()..background = const Color3(0, 0, 0);
  final hip = scene.add(Bone()), tip = hip.add(Bone());
  final mesh = scene.add(
    SkinnedMesh(
      geometry,
      material,
      skin: Skin.fromBindPose(joints: [hip, tip]),
    ),
  );
  scene.add(DirectionalLight()..lookAt(const Vec3(-.3, -.2, -1)));
  AnimationClip pose(double weight) => AnimationClip(
    durationSeconds: 1,
    tracks: [
      QuaternionKeyframeTrack(
        target: 'tip',
        times: [0],
        values: [Quat.axisAngle(const Vec3(0, 0, 1), -.4 + 1.2 * weight)],
      ),
      VectorKeyframeTrack.scale(
        target: 'tip',
        times: [0],
        values: [Vec3(1 + .4 * weight, 1, 1)],
      ),
      MorphWeightKeyframeTrack(
        target: 'mesh',
        times: [0],
        values: [
          [weight],
        ],
      ),
    ],
  );
  final mixer = AnimationMixer(nodes: {'tip': tip, 'mesh': mesh});
  final from = mixer.play(pose(0))..pause();
  final to = mixer.play(pose(1), weight: 0)..pause();
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
  FrameSubmission capture(Scene scene) => FrameSubmission.capture(
    scene: scene,
    camera: camera,
    size: PhysicalSize(83, 83),
  );
  Future<ReadbackOutput> draw(FrameSubmission frame) async =>
      await backend.render(frame) as ReadbackOutput;
  final frozen = capture(scene), initial = await draw(capture(scene));
  from.crossFadeTo(to, const Duration(seconds: 1));
  to.pause();
  final outputs = <ReadbackOutput>[];
  for (final weight in [.5, 1.0]) {
    mixer.update(const Duration(milliseconds: 500));
    final actual = await draw(capture(scene));
    expect(actual.stats.uploadedBytes, 400);
    outputs.add(actual);
    expect(to.weight, weight);
  }
  for (var index = 0; index < outputs.length; index++) {
    final weight = (index + 1) / 2, actual = outputs[index];
    final expectedHip = Bone(), expectedTip = expectedHip.add(Bone());
    final expectedMesh = SkinnedMesh(
      geometry,
      material,
      skin: Skin.fromBindPose(joints: [expectedHip, expectedTip]),
    );
    expectedTip.quaternion = Quat.axisAngle(
      const Vec3(0, 0, 1),
      -.4 + 1.2 * weight,
    );
    expectedTip.scale = Vec3(1 + .4 * weight, 1, 1);
    expectedMesh.morphWeights = [weight];
    final expectedScene = Scene()
      ..background = const Color3(0, 0, 0)
      ..add(Mesh(deformedReference(expectedMesh), material))
      ..add(DirectionalLight()..lookAt(const Vec3(-.3, -.2, -1)));
    final expected = await draw(capture(expectedScene));
    var maxDifference = 0;
    for (var i = 0; i < expected.image.pixels.length; i++) {
      maxDifference = math.max(
        maxDifference,
        (expected.image.pixels[i] - actual.image.pixels[i]).abs(),
      );
    }
    expect(
      maxDifference,
      lessThanOrEqualTo(2),
      reason: 'Crossfade weight $weight',
    );
  }
  expect(
    outputs.first.image.pixels,
    isNot(orderedEquals(initial.image.pixels)),
  );
  expect(
    outputs.last.image.pixels,
    isNot(orderedEquals(outputs.first.image.pixels)),
  );
  expect(
    (await draw(frozen)).image.pixels,
    orderedEquals(initial.image.pixels),
  );
  expect(mixer.isAdvancing, isFalse);
}
