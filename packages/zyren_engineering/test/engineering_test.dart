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
