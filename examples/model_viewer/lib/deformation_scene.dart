import 'dart:typed_data';
import 'package:zyren/zyren.dart';

class DeformationRig {
  final Group root;
  final Bone tip;
  final SkinnedMesh mesh;
  final AnimationMixer mixer;
  DeformationRig._(this.root, this.tip, this.mesh, this.mixer);
}

BufferGeometry deformationRibbon() {
  const rows = 13;
  final positions = <double>[],
      normals = <double>[],
      joints = <int>[],
      weights = <double>[],
      indices = <int>[];
  for (var row = 0; row < rows; row++) {
    final y = -.9 + row * 1.8 / (rows - 1),
        influence = ((y + .15) / .6).clamp(0.0, 1.0);
    for (final x in [-.27, .27]) {
      positions.addAll([x, y, 0]);
      normals.addAll([0, 0, 1]);
      joints.addAll([0, 1, 0, 0]);
      weights.addAll([1 - influence, influence, 0, 0]);
    }
    if (row < rows - 1) {
      final i = row * 2;
      indices.addAll([i, i + 1, i + 3, i, i + 3, i + 2]);
    }
  }
  return BufferGeometry.fromAttributes(
    attributes: {
      VertexSemantic.position: VertexAttribute(
        Float32List.fromList(positions),
        format: VertexFormat.float32x3,
      ),
      VertexSemantic.normal: VertexAttribute(
        Float32List.fromList(normals),
        format: VertexFormat.float32x3,
      ),
      VertexSemantic.joints: VertexAttribute(
        Uint16List.fromList(joints),
        format: VertexFormat.uint16x4,
      ),
      VertexSemantic.weights: VertexAttribute(
        Float32List.fromList(weights),
        format: VertexFormat.float32x4,
      ),
    },
    indices: indices,
    indexFormat: IndexFormat.uint16,
    morphTargets: [
      MorphTarget(
        name: 'width',
        positions: [
          for (var i = 0; i < positions.length; i += 3) ...[
            positions[i] * .75,
            0,
            0,
          ],
        ],
      ),
    ],
  );
}

DeformationRig addDeformationRig(
  Scene scene,
  BufferGeometry geometry, {
  required double x,
  required Color3 color,
}) {
  final root = scene.add(Group()..position = Vec3(x, 0, 0));
  final base = root.add(Bone(name: 'base')..position = const Vec3(0, -.9, 0));
  final tip = base.add(Bone(name: 'tip')..position = const Vec3(0, .9, 0));
  final mesh = root.add(
    SkinnedMesh(
      geometry,
      StandardMaterial(baseColor: color, roughness: .65),
      skin: Skin.fromBindPose(
        joints: [base, tip],
        meshBindMatrix: root.worldMatrix,
      ),
    )..castShadow = true,
  );
  final mixer = AnimationMixer(nodes: {'tip': tip});
  return DeformationRig._(root, tip, mesh, mixer);
}

AnimationClip deformationClip() => AnimationClip(
  name: 'Bend',
  tracks: [
    QuaternionKeyframeTrack(
      target: 'tip',
      times: [0, 1, 2, 3, 4],
      values: [
        Quat.identity,
        Quat.axisAngle(const Vec3(0, 0, 1), .85),
        Quat.identity,
        Quat.axisAngle(const Vec3(0, 0, 1), -.6),
        Quat.identity,
      ],
    ),
  ],
);
