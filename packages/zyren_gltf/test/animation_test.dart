import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'model_test.dart' show load;
import 'support/animated_fixture.dart';

void main() {
  test(
    'imported joints and morphs deform private geometry and seek deterministically',
    () async {
      final asset = await load(animatedModel());
      final a = asset.instantiate(), b = asset.instantiate();
      final mesh = a.nodes[0]!.children.single as Mesh;
      final other = b.nodes[0]!.children.single as Mesh;
      expect(identical(mesh.geometry, other.geometry), isFalse);
      expect(asset.animations.single.events.map((e) => e.id), [
        'start',
        'middle',
        'end',
      ]);
      a.preparePose(
        animation: asset.animations.single,
        time: const Duration(milliseconds: 500),
      )();
      expect(mesh.geometry.positions.first, 3);
      expect(other.geometry.positions.first, -1);
      a.preparePose(animation: asset.animations.single, time: Duration.zero)();
      expect(mesh.geometry.positions.first, -1);
      a.preparePose(
        animation: asset.animations.single,
        time: const Duration(seconds: 1),
      )();
      expect(mesh.geometry.positions.first, 7);
      expect(mesh.geometry.normals, [0, 0, 1, 0, 0, 1, 0, 0, 1]);
    },
  );

  test('STEP and CUBICSPLINE retain glTF interpolation semantics', () async {
    final step = await load(animatedModel(morph: false, interpolation: 'STEP'));
    final instance = step.instantiate();
    instance.preparePose(
      animation: step.animations.single,
      time: const Duration(milliseconds: 999),
    )();
    expect(instance.nodes[1]!.position.x, 0);
    instance.preparePose(
      animation: step.animations.single,
      time: const Duration(seconds: 1),
    )();
    expect(instance.nodes[1]!.position.x, 4);
    final cubic = await load(
      animatedModel(morph: false, interpolation: 'CUBICSPLINE'),
    );
    final animated = cubic.instantiate();
    animated.preparePose(
      animation: cubic.animations.single,
      time: const Duration(milliseconds: 500),
    )();
    expect(animated.nodes[1]!.position.x, 3);
  });

  test(
    'invalid morph weights and changed joint parents leave the whole pose intact',
    () async {
      final asset = await load(animatedModel()), instance = asset.instantiate();
      final mesh = instance.nodes[0]!.children.single as Mesh;
      final before = mesh.geometry.capture();
      expect(
        () => instance.preparePose(
          animation: asset.animations.single,
          time: const Duration(seconds: 1),
          morphWeights: {
            0: [double.nan],
          },
        ),
        throwsArgumentError,
      );
      expect(mesh.geometry.capture(), same(before));
      expect(instance.nodes[1]!.position, Vec3.zero);
      instance.nodes[0]!.add(instance.nodes[1]!);
      expect(() => instance.preparePose(), throwsStateError);
    },
  );

  test(
    'malformed channels, palettes and event records fail during load',
    () async {
      for (final mutate in <void Function(Map<String, Object?>)>[
        (r) => ((r['skins'] as List).first as Map)['joints'] = [9],
        (r) =>
            (((r['animations'] as List).first as Map)['channels'] as List).add({
              'sampler': 0,
              'target': {'node': 1, 'path': 'translation'},
            }),
        (r) =>
            (((r['animations'] as List).first as Map)['extras']
                as Map)['zyrenEvents'] = [
              {'id': 'late', 'time': 2},
            ],
        (r) => ((r['nodes'] as List).first as Map)['weights'] = [0, 1],
        (r) =>
            (((r['animations'] as List).first as Map)['samplers'] as List)
                    .first['interpolation'] =
                'UNKNOWN',
      ]) {
        await expectLater(
          load(animatedModel(mutate: mutate)),
          throwsA(isA<AssetLoadException>()),
        );
      }
    },
  );
  test('inverse bind matrices cancel the joint bind pose', () async {
    final asset = await load(animatedModel(bindPosition: 2, morph: false));
    final instance = asset.instantiate();
    final mesh = instance.nodes[0]!.children.single as Mesh;
    expect(mesh.geometry.positions.first, -1);
    instance.preparePose(
      animation: asset.animations.single,
      time: const Duration(seconds: 1),
    )();
    expect(mesh.geometry.positions.first, 3);
  });

  test(
    'joint ancestors participate in deformation and scene closure is enforced',
    () async {
      final asset = await load(
        animatedModel(
          morph: false,
          mutate: (r) {
            (r['nodes'] as List).add({
              'scale': [2, 2, 2],
              'children': [1],
            });
            ((r['scenes'] as List).first as Map)['nodes'] = [0, 2];
          },
        ),
      );
      final instance = asset.instantiate();
      instance.preparePose(
        animation: asset.animations.single,
        time: const Duration(seconds: 1),
      )();
      final mesh = instance.nodes[0]!.children.single as Mesh;
      expect(mesh.geometry.positions.first, 6);
      await expectLater(
        load(
          animatedModel(
            mutate: (r) {
              ((r['scenes'] as List).first as Map)['nodes'] = [0];
            },
          ),
        ),
        throwsA(isA<AssetLoadException>()),
      );
    },
  );
  test(
    'rotation sampling aligns quaternion signs and normalizes cubic interpolation',
    () {
      final linear = ModelAnimationChannel(
        node: 0,
        path: ModelAnimationPath.rotation,
        components: 4,
        interpolation: ModelInterpolation.linear,
        times: [0, 1],
        values: [0, 0, 0, 1, 0, 0, 0, -1],
      );
      expect(linear.sample(const Duration(milliseconds: 500)), [0, 0, 0, 1]);
      final cubic = ModelAnimationChannel(
        node: 0,
        path: ModelAnimationPath.rotation,
        components: 4,
        interpolation: ModelInterpolation.cubicSpline,
        times: [0, 1],
        values: [
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          0,
          0,
        ],
      );
      final q = cubic.sample(const Duration(milliseconds: 500));
      expect(
        Quat(
          q[0],
          q[1],
          q[2],
          q[3],
        ).rotate(const Vec3(1, 0, 0)).distanceTo(const Vec3(0, 0, -1)),
        lessThan(1e-9),
      );
      expect(cubic.sample(const Duration(seconds: 2)), [0, 1, 0, 0]);
    },
  );

  test(
    'skin normals use inverse transpose under nonuniform joint scales',
    () async {
      final asset = await load(animatedModel(morph: false));
      final instance = asset.instantiate();
      instance.nodes[1]!.scale = const Vec3(2, 3, 4);
      instance.preparePose()();
      final mesh = instance.nodes[0]!.children.single as Mesh;
      expect(mesh.geometry.positions.take(3), [-2, -3, 0]);
      expect(mesh.geometry.normals.take(3), [0, 0, 1]);
      final snapshot = mesh.geometry.capture();
      instance.nodes[1]!.scale = const Vec3(1e-320, 1, 1);
      expect(() => instance.preparePose(), throwsArgumentError);
      expect(mesh.geometry.capture(), same(snapshot));
    },
  );
}
