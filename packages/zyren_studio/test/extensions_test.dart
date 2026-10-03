import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
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
