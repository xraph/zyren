import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_studio/authoring_agents.dart';
import 'package:zyren_studio/zyren_studio.dart';

StudioDocument fixture([
  Map<String, StudioExtensionRecord> extensions = const {},
]) => StudioDocument(
  id: 'game',
  title: 'Game',
  nodes: [StudioNode(id: 'actor', label: 'Actor')],
  extensions: extensions,
);
StudioExtensionRecord record({
  String node = 'actor',
  int version = 1,
  bool required = true,
}) => StudioExtensionRecord(
  namespace: 'test.links',
  schemaVersion: version,
  required: required,
  data: {'target': node, 'speed': 2},
);

class LinksCodec implements StudioExtensionCodec {
  @override
  String get namespace => 'test.links';
  @override
  int get schemaVersion => 1;
  @override
  void validate(StudioExtensionRecord record, StudioDocument document) {
    if (record.data['speed'] is! num || (record.data['speed'] as num) < 0) {
      throw ArgumentError('Invalid speed.');
    }
  }

  @override
  StudioExtensionRecord migrate(StudioExtensionRecord record) =>
      throw UnsupportedError('Version');
  @override
  Iterable<String> referencedNodeIds(StudioExtensionRecord record) => [
    record.data['target'] as String,
  ];
  @override
  StudioExtensionRecord remapNodeIds(
    StudioExtensionRecord record,
    Map<String, String> ids,
  ) => record.copyWith(
    data: {
      ...record.data,
      'target': ids[record.data['target']] ?? record.data['target'],
    },
  );
  @override
  StudioExtensionRecord applyOverrides(
    StudioExtensionRecord record,
    Map<String, Object?> overrides,
  ) => record.copyWith(data: {...record.data, ...overrides});
}

class LinksV2Codec extends LinksCodec {
  @override
  int get schemaVersion => 2;
  @override
  StudioExtensionRecord migrate(StudioExtensionRecord record) =>
      record.copyWith(schemaVersion: 2);
}

void main() {
  test(
    'migration is explicit and codec disposal preserves unknown records',
    () {
      final registry = StudioExtensionRegistry();
      final registration = registry.register(LinksV2Codec());
      final original = fixture({'test.links': record()});
      final migrated = registry.migrateDocument(original);
      expect(original.extensions['test.links']!.schemaVersion, 1);
      expect(migrated.extensions['test.links']!.schemaVersion, 2);
      registry.validateDocument(migrated, requireSupported: true);
      registration.dispose();
      registry.validateDocument(migrated);
      expect(
        () => registry.validateDocument(migrated, requireSupported: true),
        throwsStateError,
      );
      expect(
        StudioDocument.decode(migrated.encode()).encode(),
        migrated.encode(),
      );
    },
  );

  test('schema 1/2/3 migrate and schema 4 preserves unknown nested data', () {
    for (final version in [1, 2, 3]) {
      final old = jsonDecode(fixture().encode()) as Map<String, dynamic>;
      old['schemaVersion'] = version;
      old.remove('extensions');
      final restored = StudioDocument.decode(jsonEncode(old));
      expect(jsonDecode(restored.encode())['schemaVersion'], 4);
      expect(restored.extensions, isEmpty);
    }
    final payload = <String, Object?>{
      'nested': <Object?>[
        1,
        true,
        null,
        {'x': 'y'},
      ],
    };
    final r = StudioExtensionRecord(
      namespace: 'vendor.optional',
      schemaVersion: 18,
      required: false,
      data: payload,
    );
    (payload['nested'] as List)[0] = 99;
    final doc = fixture({'vendor.optional': r});
    final restored = StudioDocument.decode(doc.encode());
    expect(restored.extensions['vendor.optional']!.data['nested'], [
      1,
      true,
      null,
      {'x': 'y'},
    ]);
    expect(
      () => (r.data['nested'] as List).add('change'),
      throwsUnsupportedError,
    );
    expect(restored.encode(), doc.encode());
  });
  test(
    'unsupported required records preserve authoring but block activation',
    () {
      final doc = fixture({'test.links': record()});
      final registry = StudioExtensionRegistry();
      registry.validateDocument(doc);
      expect(
        () => registry.validateDocument(doc, requireSupported: true),
        throwsStateError,
      );
      registry.validateDocument(
        fixture({'test.links': record(required: false)}),
        requireSupported: true,
      );
      final known = StudioExtensionRegistry()..register(LinksCodec());
      known.validateDocument(doc, requireSupported: true);
      expect(() => known.register(LinksCodec()), throwsArgumentError);
      expect(
        () => known.validateDocument(
          fixture({'test.links': record(node: 'missing')}),
        ),
        throwsArgumentError,
      );
    },
  );
  test('invalid envelopes, payload bounds and incompatible versions fail', () {
    expect(
      () => StudioExtensionRecord(
        namespace: 'bad',
        schemaVersion: 1,
        required: false,
        data: {},
      ),
      throwsArgumentError,
    );
    expect(
      () => StudioExtensionRecord(
        namespace: 'test.links',
        schemaVersion: 0,
        required: true,
        data: {},
      ),
      throwsArgumentError,
    );
    expect(
      () => StudioExtensionRecord(
        namespace: 'test.links',
        schemaVersion: 1,
        required: true,
        data: {'x': double.nan},
      ),
      throwsArgumentError,
    );
    expect(
      () => StudioExtensionRecord(
        namespace: 'test.links',
        schemaVersion: 1,
        required: true,
        data: {'x': 'x' * (512 * 1024)},
      ),
      throwsArgumentError,
    );
    expect(() => fixture({'wrong.key': record()}), throwsArgumentError);
    final registry = StudioExtensionRegistry()..register(LinksCodec());
    expect(
      () => registry.validateDocument(
        fixture({'test.links': record(version: 2)}),
        requireSupported: true,
      ),
      throwsStateError,
    );
  });
  test(
    'extension changes participate in capture, revision and single undo',
    () {
      final registry = StudioExtensionRegistry()..register(LinksCodec());
      final scene = StudioScene(fixture(), extensionRegistry: registry);
      final before = scene.revision;
      scene.apply(
        StudioAuthoring.updateExtension(
          scene.document,
          record(),
          registry: registry,
        ),
      );
      expect(scene.revision, greaterThan(before));
      expect(scene.capture().extensions['test.links']!.data['speed'], 2);
      expect(scene.undo(), isTrue);
      expect(scene.document.extensions, isEmpty);
      expect(scene.redo(), isTrue);
      expect(scene.document.extensions['test.links']!.data['target'], 'actor');
    },
  );
  test(
    'prefab conversion remaps known references and undo restores them together',
    () {
      final registry = StudioExtensionRegistry()..register(LinksCodec());
      final scene = StudioScene(
        fixture({'test.links': record()}),
        extensionRegistry: registry,
      );
      scene.apply(
        StudioAuthoring.createPrefab(
          scene.capture(),
          'actor',
          prefabId: 'guard',
          registry: registry,
        ),
      );
      expect(
        scene.document.extensions['test.links']!.data['target'],
        'actor/actor',
      );
      expect(scene.objects.keys, contains('actor/actor'));
      expect(scene.undo(), isTrue);
      expect(scene.document.extensions['test.links']!.data['target'], 'actor');
      expect(scene.document.prefabs, isEmpty);
      expect(scene.redo(), isTrue);
      scene.apply(
        registry.applyOverrides(scene.document, 'test.links', {'speed': 4}),
      );
      expect(scene.document.extensions['test.links']!.data['speed'], 4);
      expect(scene.undo(), isTrue);
      expect(scene.document.extensions['test.links']!.data['speed'], 2);
    },
  );
  test(
    'unknown payloads block unsafe structural edits without blocking transforms',
    () {
      final doc = fixture({'test.links': record(required: false)});
      expect(() => StudioAuthoring.remove(doc, 'actor'), throwsStateError);
      expect(
        () => StudioAuthoring.createPrefab(doc, 'actor', prefabId: 'guard'),
        throwsStateError,
      );
      final moved = StudioAuthoring.updateNode(
        doc,
        'actor',
        StudioOverride(position: const Vec3(1, 0, 0)),
      );
      expect(
        moved.extensions['test.links']!.data,
        doc.extensions['test.links']!.data,
      );
      final scene = StudioScene(doc);
      expect(() => scene.apply(doc.copyWith(nodes: [])), throwsStateError);
      expect(scene.document.encode(), doc.encode());
      final registry = StudioExtensionRegistry()..register(LinksCodec());
      expect(
        () => StudioAuthoring.remove(doc, 'actor', registry: registry),
        throwsArgumentError,
      );
    },
  );
  for (final withClip in [false, true]) {
    test(
      'prefab conversion preserves unrelated slash IDs with clips=$withClip',
      () {
        final registry = StudioExtensionRegistry()..register(LinksCodec());
        final doc = fixture({'test.links': record(node: 'actor/accessory')})
            .copyWith(
              nodes: [
                StudioNode(id: 'actor', label: 'Actor'),
                StudioNode(id: 'actor/accessory', label: 'Accessory'),
              ],
              clips: [
                if (withClip)
                  StudioClip(
                    id: 'accessory-pose',
                    label: 'Accessory pose',
                    durationMicroseconds: 1,
                    tracks: {
                      'actor/accessory': [
                        StudioKeyframe(microseconds: 0, position: Vec3.zero),
                      ],
                    },
                  ),
              ],
            );
        final next = StudioAuthoring.createPrefab(
          doc,
          'actor',
          prefabId: 'guard',
          registry: registry,
        );
        expect(
          next.extensions['test.links']!.data['target'],
          'actor/accessory',
        );
        expect(
          next.expandedNodes.keys,
          containsAll(['actor/actor', 'actor/accessory']),
        );
        expect(next.expandedNodes, isNot(contains('actor/actor/accessory')));
        expect(
          next.clips.map((clip) => clip.toJson()),
          doc.clips.map((clip) => clip.toJson()),
        );
        final removed = StudioAuthoring.remove(
          doc,
          'actor',
          registry: registry,
        );
        expect(removed.expandedNodes.keys, ['actor/accessory']);
        expect(
          removed.clips.map((clip) => clip.toJson()),
          doc.clips.map((clip) => clip.toJson()),
        );
      },
    );
  }
  test(
    'prefab conversion remaps nested descendants and preserves their overrides',
    () {
      final registry = StudioExtensionRegistry()..register(LinksCodec());
      final doc = fixture({'test.links': record(node: 'rig/inner/part')})
          .copyWith(
            nodes: [
              StudioNode(
                id: 'actor',
                label: 'Actor',
                kind: StudioNodeKind.group,
              ),
              StudioNode(
                id: 'rig',
                label: 'Rig',
                parentId: 'actor',
                kind: StudioNodeKind.prefab,
                prefabId: 'assembly',
                overrides: {
                  'inner/part': StudioOverride(position: const Vec3(2, 0, 0)),
                },
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
                version: '1',
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
          );
      final scene = StudioScene(doc, extensionRegistry: registry);
      scene.apply(
        StudioAuthoring.createPrefab(
          doc,
          'actor',
          prefabId: 'guard',
          registry: registry,
        ),
      );
      expect(
        scene.document.extensions['test.links']!.data['target'],
        'actor/rig/inner/part',
      );
      expect(
        scene.objects['actor/rig/inner/part']!.position,
        const Vec3(2, 0, 0),
      );
      expect(scene.document.prefabOwners['actor/rig/inner/part'], 'actor');
      expect(scene.undo(), isTrue);
      expect(
        scene.document.extensions['test.links']!.data['target'],
        'rig/inner/part',
      );
      expect(scene.objects['rig/inner/part']!.position, const Vec3(2, 0, 0));
      expect(scene.redo(), isTrue);
      final animated = doc.copyWith(
        clips: [
          StudioClip(
            id: 'pose',
            label: 'Pose',
            durationMicroseconds: 1,
            tracks: {
              'rig/inner/part': [
                StudioKeyframe(microseconds: 0, position: Vec3.zero),
              ],
            },
          ),
        ],
      );
      expect(
        () => StudioAuthoring.createPrefab(
          animated,
          'actor',
          prefabId: 'guard',
          registry: registry,
        ),
        throwsStateError,
      );
      final detached = StudioAuthoring.updateExtension(
        animated,
        record(),
        registry: registry,
      );
      final removed = StudioAuthoring.remove(
        detached,
        'rig',
        registry: registry,
      );
      expect(removed.expandedNodes.keys, ['actor']);
      expect(removed.clips, isEmpty);
      expect(
        () => StudioAuthoring.remove(doc, 'rig', registry: registry),
        throwsArgumentError,
      );
    },
  );
  test(
    'authoring agent uses registered extension codecs for structural edits',
    () async {
      final codecs = StudioExtensionRegistry()..register(LinksCodec());
      final scene = StudioScene(
        fixture({'test.links': record()}).copyWith(
          nodes: [
            StudioNode(id: 'actor', label: 'Actor'),
            StudioNode(id: 'spare', label: 'Spare'),
          ],
        ),
        extensionRegistry: codecs,
      );
      var changes = 0;
      final provider = StudioAuthoringAgentProvider(
        scene: scene,
        instanceId: 'extensions',
        isAvailable: () => true,
        hostRevision: () => 0,
        onChanged: () => changes++,
      );
      final agents = AgentRegistry(grantedScopes: {'studio.edit'})
        ..register(provider);
      addTearDown(agents.dispose);
      Future<AgentResult> call(
        String tool,
        Map<String, Object?> arguments,
        String key,
      ) => agents.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: tool,
        arguments: arguments,
        expectedRevision: provider.revision,
        idempotencyKey: key,
      );
      final before = scene.capture().encode();
      expect(
        (await call('remove', {'targetId': 'actor'}, 'referenced')).status,
        AgentStatus.invalid,
      );
      expect(scene.capture().encode(), before);
      expect(changes, 0);
      expect(
        (await call('remove', {'targetId': 'spare'}, 'unreferenced')).status,
        AgentStatus.ok,
      );
      expect(scene.objects, isNot(contains('spare')));
      expect(
        (await call('make_prefab', {
          'targetId': 'actor',
          'prefabId': 'guard',
        }, 'prefab')).status,
        AgentStatus.ok,
      );
      expect(
        scene.document.extensions['test.links']!.data['target'],
        'actor/actor',
      );
      expect(changes, 2);
      expect(scene.undo(), isTrue);
      expect(scene.document.extensions['test.links']!.data['target'], 'actor');
      expect(scene.undo(), isTrue);
      expect(scene.objects, contains('spare'));
    },
  );
  test(
    'one extension transaction restores related prefab overrides on undo and redo',
    () {
      final registry = StudioExtensionRegistry()..register(LinksCodec());
      final doc = StudioAuthoring.createPrefab(
        fixture({'test.links': record()}),
        'actor',
        prefabId: 'guard',
        registry: registry,
      );
      final scene = StudioScene(doc, extensionRegistry: registry);
      final before = scene.capture().encode();
      final next = StudioAuthoring.updateNode(
        registry.applyOverrides(scene.capture(), 'test.links', {'speed': 4}),
        'actor/actor',
        StudioOverride(position: const Vec3(3, 0, 0)),
      );
      scene.apply(next);
      expect(scene.document.extensions['test.links']!.data['speed'], 4);
      expect(
        scene.document.nodes.single.overrides['actor']!.position,
        const Vec3(3, 0, 0),
      );
      final edited = scene.capture().encode();
      expect(scene.undo(), isTrue);
      expect(scene.capture().encode(), before);
      expect(scene.document.extensions['test.links']!.data['speed'], 2);
      expect(scene.document.nodes.single.overrides, isEmpty);
      expect(scene.objects['actor/actor']!.position, Vec3.zero);
      expect(scene.history.canUndo, isFalse);
      expect(scene.redo(), isTrue);
      expect(scene.capture().encode(), edited);
      expect(scene.history.canRedo, isFalse);
    },
  );
  test(
    'legacy schema 3 primitive documents reopen with schema 4 extensions',
    () {
      final legacy = {
        'schemaVersion': 3,
        'documentId': 'legacy-primitives',
        'title': 'Legacy primitives',
        'nodes': [
          for (final kind in [
            'box',
            'sphere',
            'cylinder',
            'cone',
            'torus',
            'plane',
          ])
            {
              'id': kind,
              'label': kind,
              'kind': kind,
              'position': [0, 0, 0],
              'scale': [1, 1, 1],
              'rotation': [0, 0, 0, 1],
              'size': [1, 1, 1],
              'visible': true,
              'color': 0x78dace,
            },
        ],
        'camera': StudioCamera().toJson(),
        'review': jsonDecode(
          StudioDocument(
            id: 'legacy-primitives',
            title: 'Legacy primitives',
            nodes: [],
          ).review.encode(),
        ),
      };
      final restored = StudioDocument.decode(jsonEncode(legacy));
      expect(restored.extensions, isEmpty);
      expect(restored.nodes.map((node) => node.kind.name), [
        'box',
        'sphere',
        'cylinder',
        'cone',
        'torus',
        'plane',
      ]);
      final extended = StudioAuthoring.updateExtension(
        restored,
        record(node: 'sphere'),
        registry: StudioExtensionRegistry()..register(LinksCodec()),
      );
      final saved = StudioScene(extended).capture().encode();
      expect(jsonDecode(saved)['schemaVersion'], 4);
      expect(
        StudioScene(StudioDocument.decode(saved)).capture().encode(),
        saved,
      );
    },
  );
  test('all schema 3 primitive kinds survive extensions', () {
    final doc = StudioDocument(
      id: 'primitives',
      title: 'Primitives',
      nodes: [
        for (final kind in StudioNodeKind.values.where((k) => k.isPrimitive))
          StudioNode(id: kind.name, label: kind.name, kind: kind),
      ],
      extensions: {
        'vendor.optional': StudioExtensionRecord(
          namespace: 'vendor.optional',
          schemaVersion: 1,
          required: false,
          data: {},
        ),
      },
    );
    expect(
      StudioScene(StudioDocument.decode(doc.encode())).capture().encode(),
      doc.encode(),
    );
  });
}
