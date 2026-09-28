import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'deformation_checks.dart' show skinBox, deformedReference;

Future<void> verifyAdditiveAnimation(NativeGpuBackend backend) async {
  final geometry = skinBox();
  final material = StandardMaterial(roughness: .8);
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
  final mixer = AnimationMixer(nodes: {'tip': tip, 'mesh': mesh});
  final clip = AnimationClip(
    tracks: [
      QuaternionKeyframeTrack(
        target: 'tip',
        times: [0, 1],
        values: [Quat.identity, Quat.axisAngle(const Vec3(0, 0, 1), .7)],
      ),
      VectorKeyframeTrack.scale(
        target: 'tip',
        times: [0, 1],
        values: [Vec3.one, const Vec3(2, 1, .75)],
      ),
      MorphWeightKeyframeTrack(
        target: 'mesh',
        times: [0, 1],
        values: [
          [.1],
          [.8],
        ],
      ),
    ],
  );
  mixer.play(clip).seek(const Duration(milliseconds: 500));
  final reference = Quat.axisAngle(const Vec3(1, 0, 0), .4);
  final overlay = mixer.play(
    AnimationClip(
      tracks: [
        QuaternionKeyframeTrack(
          target: 'tip',
          times: [0, 1],
          values: [
            reference,
            reference * Quat.axisAngle(const Vec3(0, 1, 0), .6),
          ],
        ),
        VectorKeyframeTrack.scale(
          target: 'tip',
          times: [0, 1],
          values: [const Vec3(3, 2, 1), const Vec3(4, 2, 1)],
        ),
        MorphWeightKeyframeTrack(
          target: 'mesh',
          times: [0, 1],
          values: [
            [-.2],
            [.6],
          ],
        ),
      ],
    ),
    blendMode: AnimationBlendMode.additive,
    weight: .5,
  )..seek(const Duration(seconds: 1));
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
  FrameSubmission capture(Scene scene) => FrameSubmission.capture(
    scene: scene,
    camera: camera,
    size: PhysicalSize(83, 83),
  );
  Future<ReadbackOutput> draw(FrameSubmission frame) async =>
      await backend.render(frame) as ReadbackOutput;
  final frozen = capture(scene);
  final initial = await draw(frozen);
  overlay.weight = .25;
  final changed = await draw(capture(scene));
  expect(changed.stats.uploadedBytes, 400);
  expect(changed.image.pixels, isNot(orderedEquals(initial.image.pixels)));
  for (final weight in [.25, .5]) {
    final expectedHip = Bone(), expectedTip = Bone();
    expectedHip.add(expectedTip);
    final expectedMesh = SkinnedMesh(
      geometry,
      material,
      skin: Skin.fromBindPose(joints: [expectedHip, expectedTip]),
    );
    expectedTip.quaternion =
        Quat.axisAngle(const Vec3(0, 0, 1), .35) *
        Quat.axisAngle(const Vec3(0, 1, 0), .6 * weight);
    expectedTip.scale = Vec3(1.5 + weight, 1, .875);
    expectedMesh.morphWeights = [.45 + .8 * weight];
    final expectedScene = Scene()
      ..background = const Color3(0, 0, 0)
      ..add(Mesh(deformedReference(expectedMesh), material))
      ..add(DirectionalLight()..lookAt(const Vec3(-.3, -.2, -1)));
    final expected = await draw(capture(expectedScene));
    final actual = weight == .25 ? changed : await draw(frozen);
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
      reason: 'Skin/morph additive weight $weight',
    );
  }
  expect(
    (await draw(frozen)).image.pixels,
    orderedEquals(initial.image.pixels),
  );
}
