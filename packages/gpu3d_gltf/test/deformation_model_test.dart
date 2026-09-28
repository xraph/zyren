import 'dart:typed_data';
import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';
import 'model_test.dart' show load;
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'support/deformation_fixture.dart';

Mesh triangleIn(ModelInstance instance) =>
    instance.nodes[1]!.children.whereType<Mesh>().single;

void main() {
  test(
    'skin and morph import keep shared geometry and independent instance poses',
    () async {
      final model = await load(deformationModel());
      final a = model.instantiate(), b = model.instantiate();
      final mesh = triangleIn(a) as SkinnedMesh,
          other = triangleIn(b) as SkinnedMesh;
      expect(mesh.geometry, same(other.geometry));
      expect(mesh.morphWeights, [.3, .4]);
      expect(mesh.skin.joints, [a.nodes[2], a.nodes[3]]);
      expect(mesh.vertexPosition(0), const Vec3(-4, -1, .7));
      final action = a.mixer.play(a.animations.single)..pause();
      action.seek(const Duration(seconds: 1));
      expect(mesh.morphWeights, [1, 2]);
      expect(other.morphWeights, [.3, .4]);
      a.nodes[3]!.position = const Vec3(0, 3, 0);
      expect(mesh.vertexPosition(0), const Vec3(-4, 0, 3));
      expect(other.vertexPosition(0), const Vec3(-4, -1, .7));
      action.stop();
      expect(mesh.morphWeights, [.3, .4]);
    },
  );
  test('cubic weights follow scalar grouping and allow matrix nodes', () async {
    final model = await load(
      deformationModel(
        interpolation: 'CUBICSPLINE',
        edit: (r) {
          final node = (r['nodes'] as List)[1] as Map;
          node.remove('translation');
          node['matrix'] = Mat4.identity().storage.toList();
        },
      ),
    );
    final a = model.instantiate();
    a.mixer.play(a.animations.single).seek(const Duration(seconds: 1));
    expect(triangleIn(a).morphWeights, [1.5, 2]);
  });
  test('default inverse binds and normalized joint weights load', () async {
    for (final type in [5121, 5123, 5126]) {
      final a = (await load(
        deformationModel(weightType: type, inverseBind: false),
      )).instantiate();
      expect(
        (triangleIn(a) as SkinnedMesh).skin.inverseBindMatrices.first.storage,
        Mat4.identity().storage,
      );
    }
  });
  test(
    'mesh defaults, static primitives and unskinned references share source data',
    () async {
      final model = await load(
        deformationModel(
          edit: (r) {
            final mesh = (r['meshes'] as List).single as Map;
            final primitive = Map<String, Object?>.from(
              (mesh['primitives'] as List).single,
            );
            (mesh['primitives'] as List).add(
              Map<String, Object?>.from(primitive)..remove('targets'),
            );
            final nodes = r['nodes'] as List;
            (nodes[1] as Map).remove('weights');
            nodes.add({
              'mesh': 0,
              'weights': [-1, 2],
            });
            (nodes[0]['children'] as List).add(4);
          },
        ),
      );
      final a = model.instantiate();
      final first = a.nodes[1]!.children.whereType<Mesh>().toList();
      final second = a.nodes[4]!.children.whereType<Mesh>().toList();
      expect(first.first.morphWeights, [.1, .2]);
      expect(first.last.morphWeights, isEmpty);
      expect(second.first.morphWeights, [-1, 2]);
      expect(first.first.geometry, same(second.first.geometry));
      expect(second.first, isNot(isA<SkinnedMesh>()));
      a.mixer.play(a.animations.single).seek(const Duration(seconds: 1));
      expect(first.first.morphWeights, [1, 2]);
      expect(second.first.morphWeights, [-1, 2]);
    },
  );

  test('flat expansion remaps skin rows and morph deltas together', () async {
    final a = (await load(
      deformationModel(
        edit: (r) {
          final primitive =
              ((r['meshes'] as List).single['primitives'] as List).single;
          (primitive['attributes'] as Map).remove('NORMAL');
        },
      ),
    )).instantiate();
    final mesh = triangleIn(a) as SkinnedMesh;
    expect(mesh.geometry.vertexCount, 3);
    expect(mesh.vertexPosition(0), const Vec3(-4, -1, .7));
  });

  test(
    'malformed skins, morphs and channels retain field diagnostics',
    () async {
      final edits = <void Function(Map<String, Object?>)>[
        (r) => (r['skins'] as List)[0]['joints'] = [2, 2],
        (r) => (r['skins'] as List)[0]['joints'] = [2],
        (r) => (r['skins'] as List)[0]['skeleton'] = 1,
        (r) => (r['skins'] as List)[0]['inverseBindMatrices'] = 0,
        (r) => (r['nodes'] as List)[0]['children'] = [1],
        (r) => (r['nodes'] as List)[1]['skin'] = 99,
        (r) => (r['nodes'] as List)[1]['weights'] = [1],
        (r) => (r['meshes'] as List)[0]['weights'] = [1],
        (r) => (r['meshes'] as List)[0]['primitives'][0]['targets'] = [{}],
        (r) => (r['meshes'] as List)[0]['primitives'][0]['targets'] = [
          {'NORMAL': 0},
          {'TANGENT': 4},
        ],
        (r) => (r['meshes'] as List)[0]['primitives'][0]['targets'] = [
          {'POSITION': 5},
          {'POSITION': 4},
        ],
        (r) => (r['meshes'] as List)[0]['primitives'][0]['attributes'].remove(
          'WEIGHTS_0',
        ),
        (r) =>
            (r['meshes']
                    as List)[0]['primitives'][0]['attributes']['JOINTS_1'] =
                2,
        (r) =>
            (r['meshes']
                    as List)[0]['primitives'][0]['attributes']['WEIGHTS_0'] =
                2,
        (r) =>
            (r['animations'] as List)[0]['channels'][0]['target']['node'] = 2,
        (r) => (r['animations'] as List)[0]['samplers'][0]['output'] = 5,
      ];
      for (var i = 0; i < edits.length; i++) {
        await expectLater(
          load(deformationModel(edit: edits[i])),
          throwsA(
            isA<AssetLoadException>().having(
              (e) => e.fieldPath,
              'path case $i',
              isNotNull,
            ),
          ),
          reason: 'case $i',
        );
      }
    },
  );
  test(
    'sparse morphs and normalized animation outputs preserve decoded values',
    () async {
      for (final type in [5121, 5123, 5126]) {
        final a = (await load(
          deformationModel(
            sparseMorph: true,
            animationType: type,
            animationWeights: [0, 0, 1, 1],
          ),
        )).instantiate();
        a.mixer.play(a.animations.single).seek(const Duration(seconds: 1));
        expect(triangleIn(a).morphWeights, [.5, .5]);
        expect(triangleIn(a).vertexPosition(0), const Vec3(-4, -1, 1));
      }
    },
  );
  test(
    'invalid binary weights, bounds and inverse binds fail during loading',
    () async {
      for (final edit in <void Function(ByteData, List<Map<String, Object?>>)>[
        (b, v) => b.setFloat32(v[3]['byteOffset'] as int, -1, Endian.little),
        (b, v) => b.setUint8(v[2]['byteOffset'] as int, 9),
        (b, v) =>
            b.setFloat32((v[7]['byteOffset'] as int) + 12, 1, Endian.little),
        (b, v) => b.setFloat32(v[7]['byteOffset'] as int, 0, Endian.little),
        (b, v) => b.setFloat32(v[4]['byteOffset'] as int, 2, Endian.little),
      ]) {
        await expectLater(
          load(deformationModel(editBinary: edit)),
          throwsA(
            isA<AssetLoadException>().having(
              (e) => e.fieldPath,
              'path',
              isNotNull,
            ),
          ),
        );
      }
    },
  );
  test('native skin and morph limits reject before instantiation', () async {
    for (final edit in <void Function(Map<String, Object?>)>[
      (r) => (r['skins'] as List)[0]['joints'] = List.filled(257, 2),
      (r) => (r['meshes'] as List)[0]['primitives'][0]['targets'] = List.filled(
        65,
        {'POSITION': 4},
      ),
      (r) => (r['nodes'] as List)[1]['weights'] = [1e7, 0],
    ]) {
      await expectLater(
        load(deformationModel(edit: edit)),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
    }
  });
  test(
    'implicit flat normals follow each morph target position delta',
    () async {
      final instance = (await load(
        deformationModel(
          edit: (r) {
            (r['meshes'] as List)[0]['primitives'][0]['attributes'].remove(
              'NORMAL',
            );
            (r['accessors'] as List)[4]['max'] = [0, 0, 2];
          },
          editBinary: (b, v) =>
              b.setFloat32((v[4]['byteOffset'] as int) + 32, 2, Endian.little),
        ),
      )).instantiate();
      final target = triangleIn(instance).geometry.morphTargets.first;
      expect(target.normals![0], 0);
      expect(target.normals![1], closeTo(-1 / math.sqrt(5), 1e-7));
      expect(target.normals![2], closeTo(2 / math.sqrt(5) - 1, 1e-7));
    },
  );
}
