import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:test/test.dart';
import 'model_test.dart' show load, Sources, triangleIn;
import 'support/animation_fixture.dart';
import 'support/fixtures.dart';

void main() {
  test(
    'imported clips bind by index and instances own playback after release',
    () async {
      final scope = AssetScope(
        services: AssetServices(
          resolver: Sources(
            animatedModel(
              edit: (r) {
                for (final n in r['nodes'] as List) {
                  n['name'] = 'duplicate';
                }
              },
            ),
          ),
        ),
      );
      addTearDown(scope.close);
      final model = await scope.load(Gltf.asset('animated.glb')).result;
      final a = model.instantiate(), b = model.instantiate();
      expect(a, isA<Group>());
      expect(a.nodes.keys, [0, 1]);
      expect(a.animations.single, same(model.animations.single));
      expect(a.animations.single, same(b.animations.single));
      expect(triangleIn(a).geometry, same(triangleIn(b).geometry));
      final action = a.mixer.play(a.animations.single)..pause();
      b.mixer.play(b.animations.single).pause();
      action.seek(const Duration(seconds: 1));
      expect(a.nodes[0]!.position, const Vec3(0, .5, 0));
      expect(b.nodes[0]!.position, Vec3.zero);
      expect(a.mixer.id, isNot(b.mixer.id));
      expect(() => a.nodes.clear(), throwsUnsupportedError);
      expect(() => model.animations.clear(), throwsUnsupportedError);
      scope.release(model);
      action.seek(const Duration(seconds: 2));
      expect(a.nodes[0]!.position, const Vec3(0, 1, 0));
      action.stop();
      expect(a.nodes[0]!.position, const Vec3(1, 2, 3));
      expect(() => model.instantiate(), throwsStateError);
    },
  );

  test('scene filtering keeps clip indices and full source duration', () async {
    final model = await load(
      animatedModel(
        edit: (r) {
          (r['nodes'] as List).add({'name': 'other'});
          (r['scenes'] as List).add({
            'nodes': [2],
          });
          (r['animations'] as List).add({
            'name': 'other',
            'samplers': [
              {'input': 1, 'output': 2},
            ],
            'channels': [
              {
                'sampler': 0,
                'target': {'node': 2, 'path': 'translation'},
              },
            ],
          });
        },
      ),
    );
    final first = model.instantiate(),
        second = model.instantiate(sceneIndex: 1);
    expect(first.animations.map((c) => c.name), ['Lift', 'other']);
    expect(first.animations[1].tracks, isEmpty);
    expect(second.animations[0].tracks, isEmpty);
    expect(second.animations[0].durationSeconds, 2);
    second.mixer.play(second.animations[1]).seek(const Duration(seconds: 1));
    expect(second.nodes[2]!.position.y, .5);
    expect(first.nodes.containsKey(2), isFalse);
  });

  test(
    'step and cubic vectors preserve late starts and tangent units',
    () async {
      final step = await load(
        animatedModel(times: [1, 3], interpolation: 'STEP'),
      );
      final track = step.animations.single.tracks.single as VectorKeyframeTrack;
      expect(track.sample(0), Vec3.zero);
      expect(track.sample(2), Vec3.zero);
      expect(track.sample(3), const Vec3(0, 1, 0));
      final cubic = await load(
        animatedModel(
          times: [1, 3],
          interpolation: 'CUBICSPLINE',
          values: [0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0],
        ),
      );
      final spline =
          cubic.animations.single.tracks.single as VectorKeyframeTrack;
      expect(spline.sample(2), const Vec3(0, 2, 0));
      expect(spline.outTangents!.first.y, 4);
    },
  );

  test(
    'quaternion outputs accept normalized integer formats and cubic tangents',
    () async {
      for (final type in [5120, 5121, 5122, 5123, 5126]) {
        final model = await load(
          animatedModel(
            path: 'rotation',
            componentType: type,
            values: [0, 0, 0, 1, 0, 0, 1, 0],
          ),
        );
        final track =
            model.animations.single.tracks.single as QuaternionKeyframeTrack;
        expect(track.sample(1).z, closeTo(.70710678, 1e-6));
      }
      final model = await load(
        animatedModel(
          path: 'rotation',
          interpolation: 'CUBICSPLINE',
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
            2,
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
          ],
        ),
      );
      final track =
          model.animations.single.tracks.single as QuaternionKeyframeTrack;
      expect(track.outTangents!.first.z, 2);
      expect(track.sample(1).z, closeTo(1 / 2.2360679775, 1e-6));
    },
  );

  test(
    'malformed channels, formats and timelines report field diagnostics',
    () async {
      final edits = <void Function(Map<String, Object?>)>[
        (r) => (r['animations'] as List).clear(),
        (r) => (r['animations'] as List)[0]['channels'] = [],
        (r) => (r['animations'] as List)[0]['channels'].add({
          'sampler': 0,
          'target': {'node': 0, 'path': 'translation'},
        }),
        (r) =>
            (r['animations'] as List)[0]['channels'][0]['target']['node'] = 99,
        (r) => (r['animations'] as List)[0]['samplers'][0]['interpolation'] =
            'BEZIER',
        (r) => (r['animations'] as List)[0]['samplers'][0]['output'] = 1,
        (r) => (r['accessors'] as List)[1].remove('min'),
        (r) => (r['accessors'] as List)[1]['max'] = [8],
        (r) => (r['bufferViews'] as List)[1]['target'] = 34962,
        (r) => (r['bufferViews'] as List)[2]['byteStride'] = 12,
        (r) {
          final n = (r['nodes'] as List)[0];
          n.remove('translation');
          n['matrix'] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
        },
      ];
      for (var i = 0; i < edits.length; i++) {
        await expectLater(
          load(animatedModel(edit: edits[i])),
          throwsA(
            isA<AssetLoadException>()
                .having((e) => e.code, 'code $i', AssetLoadError.invalidData)
                .having((e) => e.fieldPath, 'field $i', isNotNull)
                .having((e) => e.issue.sourceUri, 'source $i', isNotNull),
          ),
        );
      }
      for (final times in [
        [0.0, 0.0],
        [-1.0, 2.0],
        [2.0, 1.0],
      ]) {
        await expectLater(
          load(animatedModel(times: times)),
          throwsA(
            isA<AssetLoadException>().having(
              (e) => e.code,
              'code',
              AssetLoadError.invalidData,
            ),
          ),
        );
      }
      await expectLater(
        load(animatedModel(path: 'rotation', values: [0, 0, 0, 2, 0, 0, 0, 1])),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.fieldPath,
            'path',
            contains('output'),
          ),
        ),
      );
    },
  );

  test(
    'animation budgets count expanded channels and participate in cache keys',
    () async {
      const limits = GltfLimits(maxAnimationKeyframes: 1);
      await expectLater(
        load(animatedModel(), options: const GltfOptions(limits: limits)),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
      expect(limits, isNot(const GltfLimits()));
      await expectLater(
        load(
          animatedModel(
            edit: (r) {
              (r['animations'] as List)[0]['channels'].add({
                'sampler': 0,
                'target': {'node': 1, 'path': 'translation'},
              });
            },
          ),
          options: const GltfOptions(
            limits: GltfLimits(maxAnimationKeyframes: 3),
          ),
        ),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
    },
  );

  test('sparse output values decode before interpolation', () async {
    final source = animatedModel();
    final header = ByteData.sublistView(source);
    final offset =
        source.length - (20 + header.getUint32(12, Endian.little) + 8);
    final extra = ByteData(16)
      ..setUint8(0, 1)
      ..setFloat32(8, 4, Endian.little);
    final bytes = editModel(source, (r) {
      final views = r['bufferViews'] as List;
      views.addAll([
        {'buffer': 0, 'byteOffset': offset, 'byteLength': 1},
        {'buffer': 0, 'byteOffset': offset + 4, 'byteLength': 12},
      ]);
      final a = (r['accessors'] as List)[2];
      a.remove('bufferView');
      a['sparse'] = {
        'count': 1,
        'indices': {'bufferView': 3, 'componentType': 5121},
        'values': {'bufferView': 4},
      };
    }, appendBinary: extra.buffer.asUint8List());
    final model = await load(bytes);
    final instance = model.instantiate();
    instance.mixer
        .play(instance.animations.single)
        .seek(const Duration(seconds: 1));
    expect(instance.nodes[0]!.position, const Vec3(0, 2, 0));
  });

  test(
    'channels without nodes are ignored and shared samplers bind distinct nodes',
    () async {
      final ignored = await load(
        animatedModel(
          edit: (r) {
            (r['animations'] as List)[0]['channels'][0]['target'].remove(
              'node',
            );
          },
        ),
      );
      expect(ignored.animations.single.tracks, isEmpty);
      final shared = await load(
        animatedModel(
          edit: (r) {
            (r['animations'] as List)[0]['channels'].add({
              'sampler': 0,
              'target': {'node': 1, 'path': 'translation'},
            });
          },
        ),
      );
      final instance = shared.instantiate();
      instance.mixer
          .play(instance.animations.single)
          .seek(const Duration(seconds: 1));
      expect(
        instance.nodes.values.every((n) => n.position == const Vec3(0, .5, 0)),
        isTrue,
      );
    },
  );

  test('singular scale keys retain explicit unsupported errors', () async {
    for (final source in [animatedModel(path: 'scale')]) {
      await expectLater(
        load(source),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.unsupportedFeature,
          ),
        ),
      );
    }
    final model = await load(
      animatedModel(path: 'scale', values: [-1, 2, 1, -2, 4, 1]),
    );
    final instance = model.instantiate();
    instance.mixer
        .play(instance.animations.single)
        .seek(const Duration(seconds: 1));
    expect(instance.nodes[0]!.scale, const Vec3(-1.5, 3, 1));
  });

  test(
    'clip, channel and decoded allocation limits reject before publication',
    () async {
      final doubled = animatedModel(
        edit: (r) {
          final a = r['animations'] as List;
          a.add(a.first);
        },
      );
      for (final limits in [
        const GltfLimits(maxAnimations: 1),
        const GltfLimits(maxAnimationChannels: 1),
      ]) {
        await expectLater(
          load(doubled, options: GltfOptions(limits: limits)),
          throwsA(
            isA<AssetLoadException>().having(
              (e) => e.code,
              'code',
              AssetLoadError.limitExceeded,
            ),
          ),
        );
      }
      final scope = AssetScope(
        services: AssetServices(
          resolver: Sources(animatedModel()),
          limits: const AssetLimits(maxDecodedBytes: 128),
        ),
      );
      addTearDown(scope.close);
      await expectLater(
        scope.load(Gltf.asset('animated.glb')).result,
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
      for (final limits in [
        const GltfLimits(maxAnimations: 0),
        const GltfLimits(maxAnimationChannels: 4097),
        const GltfLimits(maxAnimationKeyframes: 1000001),
      ]) {
        expect(
          () =>
              Gltf.asset('animated.glb', options: GltfOptions(limits: limits)),
          throwsRangeError,
        );
      }
    },
  );

  test('static assets expose empty animation collections', () async {
    final model = await load(triangleModel());
    expect(model.animations, isEmpty);
    expect(model.instantiate().animations, isEmpty);
  });
}
