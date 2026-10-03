import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio/animation.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import '../../zyren/test/support/fakes.dart';

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
    'one history restores transforms, structure, materials, clips and review',
    () async {
      final scene = StudioScene(
        StudioDocument(
          id: 'history',
          title: 'History',
          nodes: [StudioNode(id: 'box', label: 'Box')],
        ),
      );
      final engine = await SceneEngine.create(
        scene: scene.scene,
        camera: scene.camera,
        rendererFactory: () async => TestRenderer([]),
        plugins: [scene.tools, scene.engineering],
      );
      addTearDown(engine.dispose);
      final box = scene.objects['box']!;
      scene.edit(
        () => scene.tools.transform(box, position: const Vec3(2, 0, 0)),
      );
      expect(scene.undo(), isTrue);
      expect(scene.objects['box'], same(box));
      expect(box.position.x, 0);
      expect(scene.redo(), isTrue);
      scene.apply(
        StudioAuthoring.updateNode(
          scene.capture(),
          'box',
          StudioOverride(
            material: StudioMaterial(
              kind: StudioMaterialKind.standard,
              metallic: .8,
            ),
          ),
        ),
      );
      expect((scene.objects['box'] as Mesh).material, isA<StandardMaterial>());
      expect(scene.undo(), isTrue);
      expect((scene.objects['box'] as Mesh).material, isA<DiffuseMaterial>());
      expect(scene.redo(), isTrue);
      scene.apply(
        StudioAuthoring.createPrefab(
          scene.capture(),
          'box',
          prefabId: 'assembly',
        ),
      );
      expect(scene.objects.keys, contains('box/box'));
      scene.apply(
        StudioAuthoring.instancePrefab(scene.capture(), 'assembly', id: 'copy'),
      );
      expect(scene.objects.keys, contains('copy/box'));
      expect(scene.undo(), isTrue);
      expect(scene.objects.keys, isNot(contains('copy')));
      expect(scene.redo(), isTrue);
      final clip = StudioAuthoring.putKeyframe(
        scene.capture(),
        clipId: 'move',
        nodeId: 'box/box',
        frame: StudioKeyframe(microseconds: 0, position: Vec3.zero),
        durationMicroseconds: 1000000,
      );
      scene.apply(clip);
      expect(scene.undo(), isTrue);
      expect(scene.document.clips, isEmpty);
      expect(scene.redo(), isTrue);
      final current = scene.capture();
      scene.apply(
        current.copyWith(
          review: EngineeringDocument(
            id: current.id,
            objects: [EngineeringObject(id: 'source', label: 'Source')],
            annotations: [
              EngineeringAnnotation(
                id: 'note',
                objectId: 'source',
                text: 'Check fit',
                anchor: Vec3.zero,
              ),
            ],
          ),
        ),
      );
      expect(scene.engineering.document.annotations.length, 1);
      expect(scene.undo(), isTrue);
      expect(scene.engineering.document.annotations, isEmpty);
      expect(scene.redo(), isTrue);
      expect(scene.engineering.document.annotations['note']!.text, 'Check fit');
      scene.objects['box']!.position = const Vec3(99, 0, 0);
      expect(scene.undo, throwsStateError);
    },
  );

  test(
    'authored preview sampling is deterministic and idle ticks do not invalidate',
    () async {
      final document = prefabDocument();
      final editor = StudioScene(document);
      final preview = StudioScene(document);
      final timeline = studioTimeline(preview, 'move');
      var invalidations = 0;
      final engine = await SceneEngine.create(
        scene: preview.scene,
        camera: preview.camera,
        rendererFactory: () async => TestRenderer([]),
        plugins: [timeline],
        onInvalidate: () => invalidations++,
      );
      addTearDown(engine.dispose);
      timeline.seek(const Duration(milliseconds: 500));
      expect(preview.objects['one/inner/part']!.position.x, 1.5);
      expect(editor.objects['one/inner/part']!.position.x, 0);
      await engine.render(elapsed: Duration.zero, width: 8, height: 8);
      final before = invalidations;
      await engine.render(
        elapsed: const Duration(milliseconds: 20),
        width: 8,
        height: 8,
      );
      expect(invalidations, before);
      timeline.seek(Duration.zero);
      timeline.seek(const Duration(milliseconds: 500));
      expect(preview.objects['one/inner/part']!.position.x, 1.5);
      expect(editor.capture().encode(), document.encode());
    },
  );

  test(
    'engineering replacement rejects stale snapshots and preserves current notes',
    () {
      final initial = EngineeringDocument(id: 'review');
      final plugin = SceneEngineeringPlugin(document: initial);
      plugin.putObject(EngineeringObject(id: 'part', label: 'Part'));
      expect(
        () => plugin.replaceDocument(initial, expected: initial),
        throwsStateError,
      );
      expect(plugin.document.objects.keys, ['part']);
      final expected = plugin.document;
      expect(
        () => plugin.replaceDocument(
          EngineeringDocument(id: 'other'),
          expected: expected,
        ),
        throwsArgumentError,
      );
      expect(plugin.document, same(expected));
      plugin.replaceDocument(initial, expected: expected);
      expect(plugin.document.objects, isEmpty);
    },
  );

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
