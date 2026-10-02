import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'package:zyren_engineering/file_store.dart';
import 'package:test/test.dart';
import '../../zyren/test/support/fakes.dart';

class MemoryStore implements EngineeringStore {
  String? value;
  Completer<void>? gate;
  bool fail = false;
  @override
  Future<String?> read() async {
    await gate?.future;
    if (fail) throw StateError('read failed');
    return value;
  }

  @override
  Future<void> write(String document) async {
    await gate?.future;
    if (fail) throw StateError('write failed');
    value = document;
  }
}

EngineeringDocument seed() => EngineeringDocument(
  id: 'pump-v1',
  objects: [
    EngineeringObject(
      id: 'a',
      label: 'Housing',
      properties: {'tag': 'P-001', 'pressure': 12.5, 'enabled': true},
    ),
    EngineeringObject(id: 'b', label: 'Cover'),
  ],
);
EngineeringAnnotation note() => EngineeringAnnotation(
  id: 'note-1',
  objectId: 'a',
  text: 'Check seal',
  anchor: const Vec3(.25, .5, 0),
);

void main() {
  late Scene scene;
  late Group parent, a, b, helper;
  late SceneEngineeringPlugin review;
  late SceneEngine engine;
  setUp(() async {
    scene = Scene();
    parent = scene.add(Group());
    a = parent.add(Group(name: 'Same display name'));
    b = parent.add(Group(name: 'Same display name'));
    helper = parent.add(Group());
    review = SceneEngineeringPlugin(
      document: seed(),
      excludeFromIsolation: (object) => identical(object, helper),
    );
    engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(),
      rendererFactory: () async => TestRenderer([]),
      plugins: [review],
    );
    review.bind('a', a);
    review.bind('b', b);
  });
  tearDown(() async => engine.dispose());

  test('version pinned sidecar resolves explicit source keys', () {
    final source = jsonEncode({
      'schemaVersion': 1,
      'modelVersion': 'export-17',
      'entries': [
        {
          'id': 'a',
          'label': 'Housing',
          'properties': {},
          'path': [0],
        },
      ],
    });
    final imported = EngineeringImport.fromSidecar(
      root: parent,
      modelVersion: 'export-17',
      source: source,
    );
    expect(imported.entries.single.object, same(a));
    expect(imported.entries.single.record.id, 'a');
    expect(
      () => EngineeringImport.fromSidecar(
        root: parent,
        modelVersion: 'export-18',
        source: source,
      ),
      throwsFormatException,
    );
    expect(
      () => EngineeringImport.fromSidecar(
        root: Group(),
        modelVersion: 'export-17',
        source: source,
      ),
      throwsFormatException,
    );
  });

  test('import reload rebinds anchors and keeps missing review records', () {
    review.putAnnotation(note());
    review.isolate({'a'});
    final replacement = parent.add(Group()..position = const Vec3(3, 0, 0));
    review.rebindImport(
      EngineeringImport([
        EngineeringImportEntry(
          record: EngineeringObject(id: 'a', label: 'Renamed housing'),
          object: replacement,
        ),
      ]),
    );
    expect(review.objectFor('a'), same(replacement));
    expect(review.objectFor('b'), isNull);
    expect(review.document.objects.containsKey('b'), isTrue);
    expect(review.worldAnchor('note-1')!.x, 3.25);
    expect(review.isolatedIds, isEmpty);
  });

  test('invalid import preserves all previous bindings and isolation', () {
    review.isolate({'a'});
    expect(
      () => review.rebindImport(
        EngineeringImport([
          EngineeringImportEntry(
            record: EngineeringObject(id: 'a', label: 'New'),
            object: b,
          ),
          EngineeringImportEntry(
            record: EngineeringObject(id: 'b', label: 'Bad'),
            object: Group(),
          ),
        ]),
      ),
      throwsArgumentError,
    );
    expect(review.objectFor('a'), same(a));
    expect(review.isolatedIds, {'a'});
    expect(
      () => EngineeringImport([
        EngineeringImportEntry(record: seed().objects['a']!, object: a),
        EngineeringImportEntry(record: seed().objects['a']!, object: b),
      ]),
      throwsArgumentError,
    );
  });

  test(
    'three-way merge combines independent notes and detects edit deletion',
    () {
      final base = seed();
      final local = EngineeringDocument(
        id: base.id,
        objects: base.objects.values,
        annotations: [note()],
      );
      final remoteNote = EngineeringAnnotation(
        id: 'remote',
        objectId: 'b',
        text: 'Check cover',
        anchor: const Vec3(0, 0, 0),
      );
      final remote = EngineeringDocument(
        id: base.id,
        objects: base.objects.values,
        annotations: [remoteNote],
      );
      final merged = EngineeringMerge(base: base, local: local, remote: remote);
      expect(merged.conflicts, isEmpty);
      expect(
        merged.document!.annotations.keys,
        containsAll(['note-1', 'remote']),
      );
      final changed = EngineeringDocument(
        id: base.id,
        objects: base.objects.values,
        annotations: [
          EngineeringAnnotation(
            id: 'note-1',
            objectId: 'a',
            text: 'Changed',
            anchor: note().anchor,
          ),
        ],
      );
      final conflict = EngineeringMerge(
        base: local,
        local: changed,
        remote: base,
      );
      expect(conflict.document, isNull);
      expect(conflict.conflicts.single.id, 'note-1');
      expect(conflict.conflicts.single.remote, isNull);
    },
  );

  test('merge catches deleted object referenced by a concurrent note', () {
    final base = seed();
    final local = EngineeringDocument(
      id: base.id,
      objects: base.objects.values,
      annotations: [note()],
    );
    final remote = EngineeringDocument(
      id: base.id,
      objects: [base.objects['b']!],
    );
    expect(
      EngineeringMerge(
        base: base,
        local: local,
        remote: remote,
      ).conflicts.single.kind,
      EngineeringRecordKind.object,
    );
  });

  test(
    'session sync uses remote version and preserves edits during write',
    () async {
      final store = SessionStore(seed());
      final base = store.value;
      review.putAnnotation(note());
      store.writeGate = Completer<void>();
      final pending = review.synchronize(store, base: base);
      await store.writeStarted.future;
      review.putObject(EngineeringObject(id: 'a', label: 'Local during write'));
      store.writeGate!.complete();
      final result = await pending;
      expect(result.written, isTrue);
      expect(store.expected, 'v0');
      expect(
        result.revision.document.annotations.containsKey('note-1'),
        isTrue,
      );
      expect(review.document.objects['a']!.label, 'Local during write');
      expect(review.hasUnsavedChanges, isTrue);
      final next = await review.synchronize(store, base: result.revision);
      expect(next.written, isTrue);
      expect(review.hasUnsavedChanges, isFalse);
    },
  );

  test(
    'session conflict and conditional write failure keep local edits',
    () async {
      final store = SessionStore(seed());
      final base = store.value;
      review.putObject(EngineeringObject(id: 'a', label: 'Local'));
      store.value = EngineeringRevision(
        version: 'v1',
        document: EngineeringDocument(
          id: base.document.id,
          objects: [
            EngineeringObject(id: 'a', label: 'Remote'),
            base.document.objects['b']!,
          ],
        ),
      );
      final conflict = await review.synchronize(store, base: base);
      expect(conflict.written, isFalse);
      expect(conflict.conflicts.single.id, 'a');
      expect(review.document.objects['a']!.label, 'Local');
      store.value = base;
      store.failWrite = true;
      await expectLater(
        review.synchronize(store, base: base),
        throwsStateError,
      );
      expect(review.document.objects['a']!.label, 'Local');
      expect(review.isBusy, isFalse);
    },
  );

  test(
    'conflict decisions match exact values and cannot resolve changed remote data',
    () {
      final base = seed();
      EngineeringDocument changed(String label) => EngineeringDocument(
        id: base.id,
        objects: [
          EngineeringObject(id: 'a', label: label),
          base.objects['b']!,
        ],
      );
      final local = changed('Local'), remote = changed('Remote');
      final conflict = EngineeringMerge(
        base: base,
        local: local,
        remote: remote,
      ).conflicts.single;
      final decision = EngineeringConflictResolution(
        conflict,
        EngineeringConflictChoice.local,
      );
      final resolved = EngineeringMerge(
        base: base,
        local: local,
        remote: remote,
        resolutions: [decision],
      );
      expect(resolved.document!.objects['a']!.label, 'Local');
      final stale = EngineeringMerge(
        base: base,
        local: local,
        remote: changed('New remote'),
        resolutions: [decision],
      );
      expect(stale.document, isNull);
      expect(stale.conflicts, hasLength(1));
      expect(
        () => EngineeringMerge(
          base: base,
          local: local,
          remote: remote,
          resolutions: [decision, decision],
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'object deletion conflict can retain the part needed by concurrent notes',
    () {
      final base = seed();
      final local = EngineeringDocument(
        id: base.id,
        objects: base.objects.values,
        annotations: [note()],
      );
      final remote = EngineeringDocument(
        id: base.id,
        objects: [base.objects['b']!],
      );
      final conflict = EngineeringMerge(
        base: base,
        local: local,
        remote: remote,
      ).conflicts.single;
      final resolved = EngineeringMerge(
        base: base,
        local: local,
        remote: remote,
        resolutions: [
          EngineeringConflictResolution(
            conflict,
            EngineeringConflictChoice.local,
          ),
        ],
      );
      expect(resolved.document!.objects.containsKey('a'), isTrue);
      expect(resolved.document!.annotations.containsKey('note-1'), isTrue);
    },
  );

  test(
    'session applies acknowledged decisions and marks the persisted merge clean',
    () async {
      final store = SessionStore(seed());
      final base = store.value;
      review.putObject(EngineeringObject(id: 'a', label: 'Local'));
      store.value = EngineeringRevision(
        version: 'remote',
        document: EngineeringDocument(
          id: base.document.id,
          objects: [
            EngineeringObject(id: 'a', label: 'Remote'),
            base.document.objects['b']!,
          ],
        ),
      );
      final blocked = await review.synchronize(store, base: base);
      final result = await review.synchronize(
        store,
        base: base,
        resolutions: [
          EngineeringConflictResolution(
            blocked.conflicts.single,
            EngineeringConflictChoice.local,
          ),
        ],
      );
      expect(result.written, isTrue);
      expect(store.value.document.objects['a']!.label, 'Local');
      expect(review.hasUnsavedChanges, isFalse);
    },
  );

  test(
    'stale session reads and simultaneous file saves preserve current edits',
    () async {
      final store = SessionStore(seed())..readGate = Completer<void>();
      final base = store.value;
      final pending = review.synchronize(store, base: base);
      await expectLater(review.save(MemoryStore()), throwsStateError);
      review.putAnnotation(note());
      store.readGate!.complete();
      await expectLater(pending, throwsStateError);
      expect(store.writes, 0);
      expect(review.document.annotations.containsKey('note-1'), isTrue);
      expect(review.isBusy, isFalse);
    },
  );

  test('records copy metadata and bind stable IDs independently of names', () {
    final properties = <String, Object?>{'tag': 'P-002'};
    final record = EngineeringObject(
      id: 'c',
      label: 'Valve',
      properties: properties,
    );
    properties['tag'] = 'changed';
    expect(record.properties['tag'], 'P-002');
    expect(() => record.properties['tag'] = 'bad', throwsUnsupportedError);
    expect(review.idFor(a), 'a');
    expect(review.idFor(b), 'b');
    expect(() => review.bind('a', b), throwsStateError);
    expect(() => review.bind('b', a), throwsStateError);
    expect(() => review.bind('a', Group()), throwsArgumentError);
    expect(() => review.bind('missing', a), throwsArgumentError);
  });

  test('annotations track hierarchy transforms and convert picked anchors', () {
    parent.position = const Vec3(3, 4, 5);
    parent.scale = const Vec3(2, 3, 4);
    a.quaternion = Quat.axisAngle(const Vec3(0, 0, 1), math.pi / 2);
    review.putAnnotation(note());
    final world = review.worldAnchor('note-1')!;
    expect(world.distanceTo(const Vec3(2, 4.75, 5)), lessThan(1e-9));
    expect(
      review.localAnchor('a', world).distanceTo(note().anchor),
      lessThan(1e-9),
    );
    a.position = const Vec3(1, 0, 0);
    expect(review.worldAnchor('note-1')!.x, closeTo(4, 1e-9));
  });

  test(
    'removal releases bindings and leaves persistent records for rebinding',
    () async {
      review.putAnnotation(note());
      parent.remove(a);
      await Future<void>.delayed(Duration.zero);
      expect(review.objectFor('a'), isNull);
      expect(review.worldAnchor('note-1'), isNull);
      expect(review.document.objects.containsKey('a'), isTrue);
      final replacement = parent.add(Group());
      review.bind('a', replacement);
      expect(review.worldAnchor('note-1'), note().anchor);
    },
  );

  test(
    'isolation preserves paths, descendants, helpers and external visibility',
    () {
      final hiddenChild = a.add(Group()..visible = false);
      final hiddenBranch = scene.add(Group()..visible = false);
      parent.visible = false;
      review.isolate({'a'});
      expect(parent.visible, isTrue);
      expect(a.visible, isTrue);
      expect(b.visible, isFalse);
      expect(helper.visible, isTrue);
      expect(hiddenChild.visible, isFalse);
      b.visible = true;
      review.restoreVisibility();
      expect(parent.visible, isFalse);
      expect(b.visible, isTrue);
      expect(hiddenBranch.visible, isFalse);
    },
  );

  test(
    'switching isolation validates first and restores on target removal',
    () async {
      review.isolate({'a'});
      expect(() => review.isolate({'missing'}), throwsStateError);
      expect(b.visible, isFalse);
      review.isolate({'b'});
      expect(a.visible, isFalse);
      expect(b.visible, isTrue);
      parent.remove(b);
      await Future<void>.delayed(Duration.zero);
      expect(a.visible, isTrue);
      expect(review.isolatedIds, isEmpty);
    },
  );

  test(
    'JSON rejects schema, duplicates, dangling notes and nonfinite anchors',
    () {
      final value = jsonDecode(seed().encode()) as Map<String, dynamic>;
      void reject(Map<String, dynamic> bad) => expect(
        () => EngineeringDocument.decode(jsonEncode(bad)),
        throwsFormatException,
      );
      reject({...value, 'schemaVersion': 2});
      reject({
        ...value,
        'objects': [value['objects'][0], value['objects'][0]],
      });
      reject({
        ...value,
        'annotations': [
          {
            'id': 'n',
            'objectId': 'missing',
            'text': 'note',
            'anchor': [0, 0, 0],
          },
        ],
      });
      reject({
        ...value,
        'annotations': [
          {
            'id': 'n',
            'objectId': 'a',
            'text': 'note',
            'anchor': [0, 'x', 0],
          },
        ],
      });
      expect(
        () => EngineeringObject(
          id: 'a',
          label: 'Part',
          properties: {'bad': double.nan},
        ),
        throwsArgumentError,
      );
      expect(
        () => EngineeringObject(
          id: 'a',
          label: 'Part',
          properties: {'nested': []},
        ),
        throwsArgumentError,
      );
      expect(
        () => EngineeringDocument.decode(
          ' ' * (EngineeringDocument.maxCharacters + 1),
        ),
        throwsFormatException,
      );
      expect(() => EngineeringDocument.decode('{'), throwsFormatException);
    },
  );

  test(
    'file round trip binds fresh objects and persists annotation text',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'engineering-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileEngineeringStore(
        File('${directory.path}/nested/review.json'),
      );
      expect(await review.load(store), isFalse);
      review.putAnnotation(note());
      await review.save(store);
      expect(review.hasUnsavedChanges, isFalse);
      final second = SceneEngineeringPlugin(document: seed());
      final nextScene = Scene();
      final replacement = nextScene.add(Group());
      final nextEngine = await SceneEngine.create(
        scene: nextScene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [second],
      );
      addTearDown(nextEngine.dispose);
      expect(await second.load(store), isTrue);
      second.bind('a', replacement);
      expect(second.document.annotations['note-1']!.text, 'Check seal');
      expect(second.worldAnchor('note-1'), note().anchor);
      second.putObject(EngineeringObject(id: 'a', label: 'New housing'));
      await second.save(store);
      expect(
        EngineeringDocument.decode((await store.read())!).objects['a']!.label,
        'New housing',
      );
      expect(
        directory
            .listSync(recursive: true)
            .whereType<Directory>()
            .any((dir) => dir.path.contains('.engineering-')),
        isFalse,
      );
    },
  );

  test(
    'failed and wrong-document loads leave data and isolation intact',
    () async {
      final store = MemoryStore()..value = 'invalid';
      review.isolate({'a'});
      final original = review.document;
      await expectLater(review.load(store), throwsFormatException);
      expect(review.document, same(original));
      expect(review.isolatedIds, {'a'});
      store.value = EngineeringDocument(id: 'another-model').encode();
      await expectLater(review.load(store), throwsFormatException);
      expect(review.document, same(original));
      expect(review.isBusy, isFalse);
    },
  );

  test('stale reads and detached reads cannot replace edits', () async {
    final store = MemoryStore()
      ..value = seed().encode()
      ..gate = Completer<void>();
    final loading = review.load(store);
    review.putAnnotation(note());
    store.gate!.complete();
    await expectLater(loading, throwsStateError);
    expect(review.document.annotations, contains('note-1'));
    store.gate = Completer<void>();
    final detached = review.load(store);
    await engine.dispose();
    store.gate!.complete();
    await expectLater(detached, throwsStateError);
    expect(review.document.annotations, contains('note-1'));
  });

  test('failed saves and edits during a save remain unsaved', () async {
    final store = MemoryStore()..fail = true;
    await expectLater(review.save(store), throwsStateError);
    expect(review.hasUnsavedChanges, isTrue);
    store.fail = false;
    store.gate = Completer<void>();
    final saving = review.save(store);
    await expectLater(review.save(store), throwsStateError);
    review.putAnnotation(note());
    store.gate!.complete();
    await saving;
    expect(review.hasUnsavedChanges, isTrue);
    expect(EngineeringDocument.decode(store.value!).annotations, isEmpty);
    store.gate = null;
    await review.save(store);
    expect(review.hasUnsavedChanges, isFalse);
  });

  test('detach restores isolation and releases live bindings', () async {
    review.isolate({'a'});
    await engine.dispose();
    expect(b.visible, isTrue);
    expect(review.objectFor('a'), isNull);
    expect(review.document.objects.length, 2);
  });
}

class SessionStore implements EngineeringSessionStore {
  EngineeringRevision value;
  String? expected;
  bool failWrite = false;
  Completer<void>? writeGate, readGate;
  final writeStarted = Completer<void>();
  int writes = 0;
  SessionStore(EngineeringDocument document)
    : value = EngineeringRevision(version: 'v0', document: document);
  @override
  Future<EngineeringRevision> read() async {
    await readGate?.future;
    return value;
  }

  @override
  Future<EngineeringRevision> compareAndWrite({
    required String expectedVersion,
    required EngineeringDocument document,
  }) async {
    expected = expectedVersion;
    if (!writeStarted.isCompleted) writeStarted.complete();
    await writeGate?.future;
    if (failWrite || value.version != expectedVersion) {
      throw StateError('Version conflict');
    }
    return value = EngineeringRevision(
      version: 'v${++writes}',
      document: document,
    );
  }
}
