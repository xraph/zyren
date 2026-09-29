import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:test/test.dart';
import 'model_test.dart' show load;
import 'support/fixtures.dart';

Mesh onlyMesh(ModelAsset model) =>
    model.instantiate().children.single.children.single as Mesh;

void main() {
  test(
    'small valid triangles keep the direction of generated flat normals',
    () async {
      final model = await load(
        primitiveModel(positions: [0, 0, 0, 0, 1e-9, 0, 0, 0, 1e-9]),
      );
      expect(onlyMesh(model).geometry.normals, [1, 0, 0, 1, 0, 0, 1, 0, 0]);
    },
  );
  test('repeated mesh instances cannot bypass the primitive budget', () async {
    await expectLater(
      load(
        triangleModel(
          changes: {
            'nodes': [
              {'mesh': 0},
              {'mesh': 0},
            ],
            'scenes': [
              {
                'nodes': [0, 1],
              },
            ],
          },
        ),
        options: const GltfOptions(limits: GltfLimits(maxPrimitives: 1)),
      ),
      throwsA(
        isA<AssetLoadException>()
            .having((e) => e.code, 'code', AssetLoadError.limitExceeded)
            .having((e) => e.fieldPath, 'path', 'scenes[0]'),
      ),
    );
  });
  test(
    'world transforms that cannot reach native float32 fail during loading',
    () async {
      for (final nodes in [
        [
          {
            'mesh': 0,
            'translation': [1e100, 0, 0],
          },
        ],
        [
          {
            'scale': [1e-4, 1e-4, 1e-4],
            'children': [1],
          },
          {
            'mesh': 0,
            'scale': [1e-4, 1e-4, 1e-4],
          },
        ],
      ]) {
        await expectLater(
          load(triangleModel(changes: {'nodes': nodes})),
          throwsA(
            isA<AssetLoadException>()
                .having(
                  (e) => e.code,
                  'code',
                  AssetLoadError.unsupportedFeature,
                )
                .having((e) => e.fieldPath, 'path', startsWith('nodes[')),
          ),
        );
      }
    },
  );
  test(
    'triangle strips and fans generate consistent flat normals and UVs',
    () async {
      for (final (mode, indices) in [
        (5, [0, 1, 3, 2]),
        (6, [0, 1, 2, 3]),
      ]) {
        final model = await load(
          primitiveModel(mode: mode, indices: indices, byteUvs: true),
        );
        final geometry = onlyMesh(model).geometry;
        expect(geometry.vertexCount, 6);
        expect(geometry.indices, [0, 1, 2, 3, 4, 5]);
        expect(geometry.normals, [
          for (var i = 0; i < 6; i++) ...[0, 0, 1],
        ]);
        expect(geometry.uv0, hasLength(12));
        expect(
          geometry.uv0!.every((value) => value == 0 || value == 1),
          isTrue,
        );
        expect(geometry.indexFormat, IndexFormat.uint16);
      }
    },
  );
  test('supplied normals preserve shared indexed vertices', () async {
    final model = await load(
      primitiveModel(
        indices: [0, 1, 2, 0, 2, 3],
        normals: [
          for (var i = 0; i < 4; i++) ...[0, 0, 1],
        ],
      ),
    );
    final geometry = onlyMesh(model).geometry;
    expect(geometry.vertexCount, 4);
    expect(geometry.indices, [0, 1, 2, 0, 2, 3]);
  });
  test(
    'point, segment, loop and strip modes use matching native materials',
    () async {
      for (final mode in [0, 1, 2, 3]) {
        final mesh = onlyMesh(await load(primitiveModel(mode: mode)));
        expect(mesh.material.primitiveKind, mode == 0 ? 2 : 1);
        expect(mesh.material.primitiveSize, 1);
        expect(
          mesh.geometry.topology,
          mode == 0
              ? GeometryTopology.points
              : mode == 3
              ? GeometryTopology.lineStrip
              : GeometryTopology.lineSegments,
        );
        if (mode == 2) expect(mesh.geometry.indices, [0, 1, 1, 2, 2, 3, 3, 0]);
      }
    },
  );
  test(
    'node matrices preserve mirrored TRS and scenes can share root templates',
    () async {
      final matrix = Mat4.compose(
        const Vec3(1, 2, 3),
        Quat.axisAngle(const Vec3(0, 1, 0), .3),
        const Vec3(-2, 3, 4),
      );
      final model = await load(
        triangleModel(
          changes: {
            'nodes': [
              {'name': 'reflected', 'mesh': 0, 'matrix': matrix.storage},
            ],
            'scenes': [
              {
                'name': 'A',
                'nodes': [0],
              },
              {
                'name': 'B',
                'nodes': [0],
              },
            ],
            'scene': 1,
          },
        ),
      );
      expect(model.scenes.map((s) => s.name), ['A', 'B']);
      expect(model.defaultSceneIndex, 1);
      final instance = model.instantiate(),
          other = model.instantiate(sceneIndex: 0);
      expect(instance.name, 'B');
      expect(other.name, 'A');
      expect(instance.children.single, isNot(same(other.children.single)));
      for (var i = 0; i < 16; i++) {
        expect(
          instance.children.single.localMatrix.storage[i],
          closeTo(matrix.storage[i], 1e-10),
        );
      }
    },
  );
  test(
    'invalid primitive counts and normals fail before scene publication',
    () async {
      for (final bytes in [
        primitiveModel(),
        primitiveModel(indices: [0, 1, 4]),
        primitiveModel(
          indices: [0, 1, 2],
          normals: [
            for (var i = 0; i < 4; i++) ...[0, 0, 2],
          ],
        ),
      ]) {
        await expectLater(
          load(bytes),
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
        load(
          triangleModel(
            changes: {
              'nodes': [
                {
                  'mesh': 0,
                  'scale': [0, 1, 1],
                },
              ],
            },
          ),
        ),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.unsupportedFeature,
          ),
        ),
      );
    },
  );
  test('scene and primitive budgets report their source fields', () async {
    await expectLater(
      load(
        triangleModel(),
        options: const GltfOptions(limits: GltfLimits(maxNodes: 1)),
      ),
      throwsA(
        isA<AssetLoadException>()
            .having((e) => e.fieldPath, 'path', 'nodes')
            .having((e) => e.code, 'code', AssetLoadError.limitExceeded),
      ),
    );
    await expectLater(
      load(
        triangleModel(),
        options: const GltfOptions(limits: GltfLimits(maxNodeDepth: 1)),
      ),
      throwsA(
        isA<AssetLoadException>().having(
          (e) => e.code,
          'code',
          AssetLoadError.limitExceeded,
        ),
      ),
    );
  });
}
