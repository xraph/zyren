import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_studio/zyren_studio.dart';

StudioDocument prefabDocument() => StudioDocument(
  id: 'authoring',
  title: 'Authoring',
  nodes: [
    StudioNode(
      id: 'one',
      label: 'One',
      kind: StudioNodeKind.prefab,
      prefabId: 'assembly',
    ),
    StudioNode(
      id: 'two',
      label: 'Two',
      kind: StudioNodeKind.prefab,
      prefabId: 'assembly',
      overrides: {'inner/part': StudioOverride(position: const Vec3(2, 0, 0))},
    ),
  ],
  prefabs: [
    StudioPrefab(
      id: 'part',
      label: 'Part',
      version: '1',
      nodes: [StudioNode(id: 'part', label: 'Part')],
    ),
    StudioPrefab(
      id: 'assembly',
      label: 'Assembly',
      version: '2',
      nodes: [
        StudioNode(
          id: 'inner',
          label: 'Inner',
          kind: StudioNodeKind.prefab,
          prefabId: 'part',
        ),
      ],
    ),
  ],
  clips: [
    StudioClip(
      id: 'move',
      label: 'Move',
      durationMicroseconds: 1000000,
      tracks: {
        'one/inner/part': [
          StudioKeyframe(microseconds: 0, position: Vec3.zero),
          StudioKeyframe(microseconds: 1000000, position: const Vec3(3, 0, 0)),
        ],
      },
    ),
  ],
);

void main() {
  test(
    'v1 documents migrate and v2 definitions survive capture without flattening',
    () {
      final old =
          jsonDecode(
                StudioDocument(
                  id: 'old',
                  title: 'Old',
                  nodes: [StudioNode(id: 'box', label: 'Box')],
                ).encode(),
              )
              as Map<String, dynamic>;
      old['schemaVersion'] = 1;
      old.remove('assets');
      old.remove('prefabs');
      old.remove('clips');
      expect(
        jsonDecode(
          StudioDocument.decode(jsonEncode(old)).encode(),
        )['schemaVersion'],
        2,
      );
      final doc = StudioDocument.decode(prefabDocument().encode());
      final scene = StudioScene(doc);
      expect(scene.objects['two/inner/part']!.position.x, 2);
      scene.objects['one/inner/part']!.position = const Vec3(5, 0, 0);
      scene.setMaterial(
        'one/inner/part',
        StudioMaterial(
          kind: StudioMaterialKind.standard,
          color: 0xabcdef,
          roughness: .2,
          metallic: .6,
        ),
      );
      final saved = StudioDocument.decode(scene.capture().encode());
      expect(saved.nodes.length, 2);
      expect(saved.prefabs.length, 2);
      expect(saved.clips.single.tracks.keys, ['one/inner/part']);
      final next = StudioScene(saved);
      expect(next.objects['one/inner/part']!.position.x, 5);
      expect(next.objects['two/inner/part']!.position.x, 2);
      final material =
          (next.objects['one/inner/part'] as Mesh).material as StandardMaterial;
      expect(material.color, Color3.hex(0xabcdef));
      expect(material.metallic, .6);
      expect(next.capture().encode(), saved.encode());
    },
  );

  test(
    'prefab cycles, missing paths, collisions and malformed clips fail before reconstruction',
    () {
      expect(
        () => StudioDocument(
          id: 'bad',
          title: 'Bad',
          nodes: [],
          prefabs: [
            StudioPrefab(
              id: 'self',
              label: 'Self',
              version: '1',
              nodes: [
                StudioNode(
                  id: 'a',
                  label: 'A',
                  kind: StudioNodeKind.prefab,
                  prefabId: 'self',
                ),
              ],
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => prefabDocument().copyWith(
          nodes: [
            StudioNode(
              id: 'one',
              label: 'One',
              kind: StudioNodeKind.prefab,
              prefabId: 'assembly',
              overrides: {'missing': StudioOverride(visible: false)},
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => prefabDocument().copyWith(
          nodes: [
            ...prefabDocument().nodes,
            StudioNode(id: 'one/inner', label: 'Collision'),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => StudioClip(
          id: 'bad',
          label: 'Bad',
          durationMicroseconds: 10,
          tracks: {
            'one': [
              StudioKeyframe(microseconds: 5, position: Vec3.zero),
              StudioKeyframe(microseconds: 5, position: Vec3.zero),
            ],
          },
        ),
        throwsArgumentError,
      );
      expect(
        () => StudioClip(
          id: 'bad',
          label: 'Bad',
          durationMicroseconds: 10,
          tracks: {
            'one': [
              StudioKeyframe(microseconds: 0, position: Vec3.zero),
              StudioKeyframe(
                microseconds: 5,
                position: Vec3.zero,
                scale: const Vec3(-1, 1, 1),
              ),
            ],
          },
        ),
        throwsArgumentError,
      );
      expect(() => StudioMaterial(opacity: double.nan), throwsArgumentError);
    },
  );

  test(
    'asset pins are immutable, exact and require explicit scope ownership',
    () async {
      final nested = <String, Object?>{
        'version': 'pin',
        'metadata': <Object?>['original'],
      };
      final asset = StudioAsset(
        id: 'asset',
        label: 'Asset',
        provider: 'test',
        reference: nested,
        sourceNodes: {'cad-part': 0},
      );
      (nested['metadata'] as List)[0] = 'changed';
      expect((asset.reference['metadata'] as List).single, 'original');
      expect(
        () => (asset.reference['metadata'] as List).add('x'),
        throwsUnsupportedError,
      );
      final doc = StudioDocument(
        id: 'assets',
        title: 'Assets',
        nodes: [
          StudioNode(
            id: 'model',
            label: 'Model',
            kind: StudioNodeKind.asset,
            assetId: 'asset',
          ),
        ],
        assets: [asset],
      );
      expect(() => StudioScene(doc), throwsStateError);
      final resolver = _Resolver();
      final scope = await StudioAssetScope.load(doc, resolver);
      final scene = StudioScene(doc, assets: scope);
      final imported = scene.objects['model']!.children.single.children.single;
      expect(scene.idFor(imported), 'model');
      expect(scene.sourceFor(imported), ('model', 'cad-part'));
      scene.setMaterial(
        'model',
        StudioMaterial(kind: StudioMaterialKind.unlit, color: 0x123456),
      );
      final captured = scene.capture();
      expect(captured.assets.single.reference, asset.reference);
      expect((imported as Mesh).material.color, Color3.hex(0x123456));
      imported.position = const Vec3(1, 0, 0);
      expect(scene.capture, throwsStateError);
      final different = StudioAsset(
        id: asset.id,
        label: asset.label,
        provider: asset.provider,
        reference: {'version': 'other'},
      );
      expect(() => scope.instantiate(different), throwsStateError);
      await scope.close();
      await scope.close();
      expect(resolver.closed, 1);
      expect(() => scope.instantiate(asset), throwsStateError);
    },
  );

  test(
    'cancelled asset load closes completed templates and propagates cancellation',
    () async {
      final token = StudioCancellation();
      final resolver = _Resolver(onLoad: token.cancel);
      final doc = StudioDocument(
        id: 'cancel',
        title: 'Cancel',
        nodes: [
          StudioNode(
            id: 'model',
            label: 'Model',
            kind: StudioNodeKind.asset,
            assetId: 'asset',
          ),
        ],
        assets: [
          StudioAsset(
            id: 'asset',
            label: 'Asset',
            provider: 'test',
            reference: {'version': 'pin'},
          ),
        ],
      );
      await expectLater(
        StudioAssetScope.load(doc, resolver, cancellation: token),
        throwsA(isA<LoadCancelled>()),
      );
      expect(resolver.closed, 1);
    },
  );
}

class _Resolver implements StudioAssetResolver {
  final void Function()? onLoad;
  int closed = 0;
  _Resolver({this.onLoad});
  @override
  Future<StudioAssetTemplate> load(
    StudioAsset asset,
    LoadCancellation cancellation,
  ) async {
    onLoad?.call();
    return _Template(() => closed++);
  }
}

class _Template implements StudioAssetTemplate {
  final void Function() onClose;
  _Template(this.onClose);
  @override
  StudioAssetInstance instantiate() {
    final mesh = Mesh(BoxGeometry(), DiffuseMaterial());
    return StudioAssetInstance(Group()..add(mesh), sources: {'cad-part': mesh});
  }

  @override
  Future<void> close() async {
    onClose();
  }
}
