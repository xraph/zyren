import 'package:gpu3d/gpu3d.dart';

/// One clip drives two separately bound scene hierarchies.
class AnimationLabScene {
  final scene = Scene();
  final camera = PerspectiveCamera(
    position: const Vec3(0, .4, 3.8),
    fieldOfView: 1,
  );
  final mixers = <AnimationMixer>[];
  final actions = <AnimationAction>[];
  final layers = <AnimationAction>[];
  AnimationLabScene({bool autoplay = true}) {
    scene.background = const Color3(.015, .022, .035);
    final clip = AnimationClip(
      name: 'Swing',
      tracks: [
        VectorKeyframeTrack.position(
          target: 'arm',
          times: [0, 2, 4],
          values: [
            const Vec3(0, -.7, 0),
            const Vec3(0, -.4, 0),
            const Vec3(0, -.7, 0),
          ],
          interpolation: KeyframeInterpolation.cubicSpline,
          inTangents: [Vec3.zero, Vec3.zero, Vec3.zero],
          outTangents: [Vec3.zero, Vec3.zero, Vec3.zero],
        ),
        QuaternionKeyframeTrack(
          target: 'arm',
          times: [0, 2, 4],
          values: [
            Quat.axisAngle(const Vec3(0, 0, 1), -.65),
            Quat.axisAngle(const Vec3(0, 0, 1), .65),
            Quat.axisAngle(const Vec3(0, 0, 1), -.65),
          ],
        ),
      ],
    );
    final layerClip = AnimationClip(
      name: 'Lean',
      tracks: [
        QuaternionKeyframeTrack(
          target: 'arm',
          times: [0, 1],
          values: [Quat.identity, Quat.axisAngle(const Vec3(0, 1, 0), .9)],
        ),
        VectorKeyframeTrack.position(
          target: 'arm',
          times: [0, 1],
          values: [Vec3.zero, const Vec3(0, .15, 0)],
        ),
      ],
    );
    final beam = BoxGeometry(width: .25, height: 1.4, depth: .3),
        tip = BoxGeometry(width: .55, height: .35, depth: .4),
        base = BoxGeometry(width: .8, height: .2, depth: .7);
    for (var i = 0; i < 2; i++) {
      final root = scene.add(
        Group(name: i == 0 ? 'Left' : 'Right')
          ..position = Vec3(i == 0 ? -1.3 : 1.3, 0, 0),
      );
      final color = i == 0
          ? const Color3(.1, .5, .9)
          : const Color3(.95, .4, .06);
      final material = StandardMaterial(
        baseColor: color,
        metallic: .3,
        roughness: .3,
      );
      root.add(Mesh(base, material)..position = const Vec3(0, -.95, 0));
      final arm = root.add(Group(name: 'arm'));
      arm.add(Mesh(beam, material)..position = const Vec3(0, .7, 0));
      arm.add(Mesh(tip, material)..position = const Vec3(0, 1.5, 0));
      final mixer = AnimationMixer(id: 'animation.$i', nodes: {'arm': arm});
      mixers.add(mixer);
      final playback = mixer.play(clip);
      if (i == 1) playback.seek(const Duration(seconds: 2));
      if (i == 1 || !autoplay) playback.pause();
      actions.add(playback);
      layers.add(
        mixer.play(
            layerClip,
            blendMode: AnimationBlendMode.additive,
            weight: .35,
          )
          ..seek(const Duration(seconds: 1))
          ..pause(),
      );
    }
    scene.add(
      DirectionalLight(intensity: 3)
        ..rotateY(.5)
        ..rotateX(-.4),
    );
    scene.add(
      HemisphereLight(
        intensity: 1.5,
        skyColor: const Color3(.65, .8, 1),
        groundColor: const Color3(.1, .08, .05),
      ),
    );
  }
}
