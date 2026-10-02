import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'model_test.dart' show load;
import 'support/animated_fixture.dart';

void main() {
  test(
    'poses are immutable and prepare one joint and morph deformation',
    () async {
      final asset = await load(animatedModel(bindPosition: 2));
      final instance = asset.instantiate();
      final mesh = instance.nodes[0]!.children.single as Mesh;
      final rest = instance.samplePose(initial: true);
      final end = instance.samplePose(
        animation: asset.animations.single,
        time: const Duration(seconds: 1),
      );
      final before = mesh.geometry.capture();
      expect(() => rest.nodes.clear(), throwsUnsupportedError);
      expect(() => rest.weights[0]![0] = 1, throwsUnsupportedError);
      final apply = instance.prepareBlendedPose([
        ModelPoseContribution(rest, .75),
        ModelPoseContribution(end, .25),
      ]);
      expect(mesh.geometry.capture(), same(before));
      expect(instance.nodes[1]!.position.x, 2);
      apply();
      expect(instance.nodes[1]!.position.x, 3);
      expect(mesh.geometry.positions.first, 1);
      final revision = mesh.geometry.capture();
      apply();
      expect(mesh.geometry.capture(), same(revision));
      instance.prepareSampledPose(rest)();
      expect(mesh.geometry.positions.first, -1);
    },
  );

  test('joint rotations blend before skinning and keep unit length', () async {
    final asset = await load(animatedModel(morph: false));
    final instance = asset.instantiate();
    final mesh = instance.nodes[0]!.children.single as Mesh;
    final rest = instance.samplePose(initial: true);
    instance.nodes[1]!.quaternion = Quat.axisAngle(
      const Vec3(0, 0, 1),
      math.pi,
    );
    final rotated = instance.samplePose();
    instance.prepareBlendedPose([
      ModelPoseContribution(rest, .5),
      ModelPoseContribution(rotated, .5),
    ])();
    expect(mesh.geometry.positions[0], closeTo(1, 1e-6));
    expect(mesh.geometry.positions[1], closeTo(-1, 1e-6));
    expect(mesh.geometry.normals[2], closeTo(1, 1e-6));
  });

  test(
    'additive poses use a captured reference for joints and morph weights',
    () async {
      final asset = await load(animatedModel());
      final instance = asset.instantiate();
      final mesh = instance.nodes[0]!.children.single as Mesh;
      final rest = instance.samplePose(initial: true);
      ModelPose sample(int ms) => instance.samplePose(
        animation: asset.animations.single,
        time: Duration(milliseconds: ms),
      );
      instance.prepareBlendedPose(
        [ModelPoseContribution(rest, 1)],
        additive: [
          ModelPoseContribution(sample(1000), .5, reference: sample(500)),
        ],
      )();
      expect(instance.nodes[1]!.position.x, 1);
      expect(mesh.geometry.positions.first, 1);
      final before = mesh.geometry.capture();
      expect(
        () => instance.prepareBlendedPose(
          [ModelPoseContribution(rest, 1)],
          additive: [ModelPoseContribution(sample(1000), 1)],
        ),
        throwsArgumentError,
      );
      expect(mesh.geometry.capture(), same(before));
    },
  );

  test(
    'invalid blends reject atomically and cannot cross model templates',
    () async {
      final asset = await load(animatedModel());
      final other = await load(animatedModel());
      final instance = asset.instantiate();
      final mesh = instance.nodes[0]!.children.single as Mesh;
      final rest = instance.samplePose(initial: true);
      instance.nodes[1]!.scale = const Vec3(-1, 1, 1);
      final mirrored = instance.samplePose();
      instance.prepareSampledPose(rest)();
      final before = mesh.geometry.capture();
      expect(
        () => instance.prepareBlendedPose([
          ModelPoseContribution(rest, .5),
          ModelPoseContribution(mirrored, .5),
        ]),
        throwsArgumentError,
      );
      expect(
        () => instance.prepareBlendedPose([ModelPoseContribution(rest, 0)]),
        throwsArgumentError,
      );
      expect(
        () => instance.prepareSampledPose(other.instantiate().samplePose()),
        throwsArgumentError,
      );
      expect(instance.nodes[1]!.scale, Vec3.one);
      expect(mesh.geometry.capture(), same(before));
      for (final weight in [-.1, 1.1, double.nan, double.infinity]) {
        expect(() => ModelPoseContribution(rest, weight), throwsArgumentError);
      }
    },
  );
}
