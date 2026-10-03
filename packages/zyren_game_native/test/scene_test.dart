import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/scene.dart';

Map<String, Object?> node(
  String id, {
  String kind = 'box',
  String? parent,
  GameAssetReference? asset,
}) => {
  'id': id,
  'label': id,
  'kind': kind,
  'parentId': parent,
  'position': [1, 2, 3],
  'scale': [1, 1, 1],
  'size': [2, 3, 4],
  'rotation': [0, 0, 0, 1],
  'visible': true,
  'color': 0x338866,
  if (asset != null) 'assetReference': asset.toJson(),
};
CompiledGameProject project(
  List<Map<String, Object?>> nodes, {
  List<GameAssetReference> assets = const [],
}) => CompiledGameProject(
  project: GameProject(
    id: 'scene',
    startupLevel: 'main',
    registry: GameRegistry(),
    levels: [
      GameLevel(
        id: 'main',
        scene: GameSceneIdentity('scene', '1'),
        entities: [],
      ),
    ],
  ),
  sceneNodes: {'main': nodes},
  assets: assets,
  artifactHashes: {for (final asset in assets) asset.id: asset.digest},
);
void main() {
  test(
    'runtime primitives preserve dimension and transform hierarchy without Studio',
    () async {
      final data = await GameRuntimeScene.load(
        project([
          node('parent', kind: 'group'),
          for (final kind in [
            'box',
            'sphere',
            'cylinder',
            'cone',
            'torus',
            'plane',
          ])
            node(kind, kind: kind, parent: 'parent'),
        ]),
      );
      expect(data.objects.length, 7);
      expect(data.objects['box']!.parent, same(data.objects['parent']));
      final shape = data.objects['box']!.children.single as Mesh;
      expect(shape.scale, const Vec3(2, 3, 4));
      expect(
        Vec3.fromVectorMath(shape.worldMatrix.toVectorMath().getTranslation()),
        const Vec3(2, 4, 6),
      );
      await data.close();
      await data.close();
    },
  );
  test(
    'invalid identity hierarchy and geometry fail before asset acquisition',
    () async {
      var loads = 0;
      final ref = GameAssetReference(
        id: 'model',
        revision: '1',
        uri: Uri.parse('game:///model.gltf'),
        digest: 'a' * 64,
      );
      for (final nodes in [
        [node('a'), node('a')],
        [node('a', parent: 'missing')],
        [node('a', parent: 'b'), node('b', parent: 'a')],
        [
          {
            ...node('a'),
            'size': [0, 1, 1],
          },
        ],
        [node('a', kind: 'asset', asset: ref)],
      ]) {
        await expectLater(
          GameRuntimeScene.load(
            project(nodes),
            loadAsset: (_, _) async {
              loads++;
              return GameSceneAsset(root: Group(), close: () async {});
            },
          ),
          throwsA(anything),
        );
      }
      expect(loads, 0);
    },
  );
  test('late cancelled asset closes its lease before load completes', () async {
    final ref = GameAssetReference(
      id: 'model',
      revision: '1',
      uri: Uri.parse('game:///model.gltf'),
      digest: 'a' * 64,
    );
    final entered = Completer<void>(), release = Completer<void>();
    final token = LoadCancellationSource();
    var closed = 0;
    final loaded = GameRuntimeScene.load(
      project(
        [node('model', kind: 'asset', asset: ref)],
        assets: [ref],
      ),
      cancellation: token,
      loadAsset: (_, _) async {
        entered.complete();
        await release.future;
        return GameSceneAsset(
          root: Group(),
          close: () async {
            closed++;
          },
        );
      },
    );
    final failure = expectLater(loaded, throwsA(anything));
    await entered.future;
    token.cancel();
    release.complete();
    await failure;
    expect(closed, 1);
  });
  test(
    'asset leases close once in reverse order even when one close fails',
    () async {
      final a = GameAssetReference(
        id: 'a',
        revision: '1',
        uri: Uri.parse('game:///a.gltf'),
        digest: 'a' * 64,
      );
      final b = GameAssetReference(
        id: 'b',
        revision: '1',
        uri: Uri.parse('game:///b.gltf'),
        digest: 'b' * 64,
      );
      final closed = <String>[];
      final data = await GameRuntimeScene.load(
        project(
          [
            node('a', kind: 'asset', asset: a),
            node('b', kind: 'asset', asset: b),
          ],
          assets: [a, b],
        ),
        loadAsset: (ref, _) async => GameSceneAsset(
          root: Group(),
          close: () async {
            closed.add(ref.id);
            if (ref.id == 'b') throw StateError('fixture close failure');
          },
        ),
      );
      await expectLater(data.close(), throwsStateError);
      await expectLater(data.close(), throwsStateError);
      expect(closed, ['b', 'a']);
    },
  );
}
