import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:shader_lab_effects/shader_lab_effects.dart';

class GeometryLabScene {
  final scene = Scene();
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
  late final SkinnedMesh skin;
  late final InstancedMesh instances;
  late final AnimationMixer mixer;
  late final AnimationAction action;
  final patterns = <PatternMaterialPlugin>[];
  GeometryLabScene({
    bool autoplay = true,
    UnsupportedEffects unsupported = UnsupportedEffects.reject,
  }) {
    scene.background = const Color3(.015, .022, .035);
    final geometry = _ribbon();
    final root = scene.add(Group()..position = const Vec3(-1, 0, 0));
    final base = root.add(Bone()), tip = base.add(Bone());
    skin = root.add(
      SkinnedMesh(
        geometry,
        DiffuseMaterial(color: const Color3(.1, .7, 1)),
        skin: Skin.fromBindPose(
          joints: [base, tip],
          meshBindMatrix: root.worldMatrix,
        ),
      ),
    );
    instances = scene.add(
      InstancedMesh(
        geometry,
        DiffuseMaterial(color: const Color3(1, .5, .12)),
        count: 12,
      ),
    );
    instances.setTransforms(
      0,
      List.generate(
        12,
        (i) => Mat4.compose(
          Vec3(.5 + (i % 3) * .5, (i ~/ 3) * .55 - .8, 0),
          Quat.identity,
          Vec3(i.isEven ? .45 : -.45, .24, 1),
        ),
      ),
    );
    mixer = AnimationMixer(nodes: {'tip': tip});
    action = mixer.play(
      AnimationClip(
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
      ),
    );
    if (!autoplay) action.pause();
    for (final mesh in [skin, instances]) {
      mesh.setMorphWeight(0, .3);
      patterns.add(
        PatternMaterialPlugin(
          mesh,
          id: 'geometry.pattern.${patterns.length}',
          unsupported: unsupported,
        ),
      );
    }
    scene.add(DirectionalLight()..lookAt(const Vec3(.3, -.3, -1)));
  }

  void setWidth(double value) {
    skin.setMorphWeight(0, value);
    instances.setMorphWeight(0, value);
  }
}

BufferGeometry _ribbon() {
  final p = <double>[],
      n = <double>[],
      uv = <double>[],
      weights = <double>[],
      joints = <int>[],
      indices = <int>[];
  for (var row = 0; row <= 12; row++) {
    final y = -.9 + row * .15, influence = ((y + .15) / .6).clamp(0.0, 1.0);
    for (final x in [-.27, .27]) {
      p.addAll([x, y, 0]);
      n.addAll([0, 0, 1]);
      uv.addAll([(x + .27) / .54, row / 12]);
      joints.addAll([0, 1, 0, 0]);
      weights.addAll([1 - influence, influence, 0, 0]);
    }
    if (row < 12) {
      final i = row * 2;
      indices.addAll([i, i + 1, i + 3, i, i + 3, i + 2]);
    }
  }
  return BufferGeometry.fromAttributes(
    attributes: {
      VertexSemantic.position: VertexAttribute(
        Float32List.fromList(p),
        format: VertexFormat.float32x3,
      ),
      VertexSemantic.normal: VertexAttribute(
        Float32List.fromList(n),
        format: VertexFormat.float32x3,
      ),
      VertexSemantic.uv0: VertexAttribute(
        Float32List.fromList(uv),
        format: VertexFormat.float32x2,
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
    morphTargets: [
      MorphTarget(
        name: 'width',
        positions: [
          for (var i = 0; i < p.length; i += 3) ...[p[i] * .75, 0, 0],
        ],
      ),
    ],
  );
}
