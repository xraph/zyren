import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

Mesh morphMesh() => Mesh(
  BufferGeometry(
    positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
    indices: [0, 1, 2],
    normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
    morphTargets: [
      MorphTarget(positions: [0, 0, 1, 0, 0, 1, 0, 0, 1]),
      MorphTarget(positions: [1, 0, 0, 1, 0, 0, 1, 0, 0]),
    ],
  ),
  UnlitMaterial(),
);

void main() {
  test('weight tracks copy nested keys and interpolate each component', () {
    final values = [
      [-1.0, 2.0],
      [1.0, 4.0],
    ];
    final track = MorphWeightKeyframeTrack(
      target: 'mesh',
      times: [1, 3],
      values: values,
    );
    values[0][0] = 99;
    expect(track.sample(0), [-1, 2]);
    expect(track.sample(2), [0, 3]);
    expect(() => track.values[0][0] = 3, throwsUnsupportedError);
    expect(() => track.sample(2)[0] = 3, throwsUnsupportedError);
    final step = MorphWeightKeyframeTrack(
      target: 'mesh',
      times: [1, 3],
      values: [
        [0, 1],
        [2, 3],
      ],
      interpolation: KeyframeInterpolation.step,
    );
    expect(step.sample(2), [0, 1]);
    final cubic = MorphWeightKeyframeTrack(
      target: 'mesh',
      times: [1, 3],
      values: [
        [0, 1],
        [2, 3],
      ],
      interpolation: KeyframeInterpolation.cubicSpline,
      inTangents: [
        [0, 0],
        [0, 0],
      ],
      outTangents: [
        [4, -4],
        [0, 0],
      ],
    );
    expect(cubic.sample(2), [2, 1]);
  });

  test(
    'one node binding updates all primitives and restores independent rest poses',
    () {
      final a = morphMesh()..morphWeights = [.2, .4];
      final b = morphMesh()..morphWeights = [.6, .8];
      final other = morphMesh();
      final mixer = AnimationMixer(
        nodes: {'node': Group()},
        morphTargets: {
          'node': [a, b],
        },
      );
      final clip = AnimationClip(
        tracks: [
          MorphWeightKeyframeTrack(
            target: 'node',
            times: [0, 2],
            values: [
              [0, 0],
              [2, 4],
            ],
          ),
        ],
      );
      final action = mixer.play(clip, weight: .5)..pause();
      action.seek(const Duration(seconds: 1));
      expect(a.morphWeights, [.6, 1.2]);
      expect(b.morphWeights, [.8, 1.4]);
      expect(other.morphWeights, [0, 0]);
      action.stop();
      expect(a.morphWeights, [.2, .4]);
      expect(b.morphWeights, [.6, .8]);
    },
  );

  test('mixed tracks publish atomically and reject mismatched bindings', () {
    final mesh = morphMesh();
    final mixer = AnimationMixer(nodes: {'mesh': mesh});
    final track = MorphWeightKeyframeTrack(
      target: 'mesh',
      times: [0, 2],
      values: [
        [0, 0],
        [0, 0],
      ],
      interpolation: KeyframeInterpolation.cubicSpline,
      inTangents: [
        [0, 0],
        [-1e308, 0],
      ],
      outTangents: [
        [1e308, 0],
        [0, 0],
      ],
    );
    final action = mixer.play(
      AnimationClip(
        tracks: [
          VectorKeyframeTrack.position(
            target: 'mesh',
            times: [0, 2],
            values: [Vec3.zero, Vec3.one],
          ),
          track,
        ],
      ),
    )..pause();
    expect(() => action.seek(const Duration(seconds: 1)), throwsArgumentError);
    expect(mesh.position, Vec3.zero);
    expect(mesh.morphWeights, [0, 0]);
    expect(action.time, Duration.zero);
    expect(
      () => mixer.play(
        AnimationClip(
          tracks: [
            MorphWeightKeyframeTrack(
              target: 'mesh',
              times: [0],
              values: [
                [1],
              ],
            ),
          ],
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => MorphWeightKeyframeTrack(
        target: 'mesh',
        times: [0, 1],
        values: [
          [0],
          [0, 1],
        ],
      ),
      throwsArgumentError,
    );
  });
}
