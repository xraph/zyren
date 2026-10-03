import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';
import 'package:zyren_collaboration/file_store.dart';

void main() {
  final id = SceneObjectId(source: 'asset@1', key: 'box');
  SceneSnapshot initial() => SceneSnapshot(
    sceneId: 'scene',
    epoch: 'one',
    objects: [SceneObjectState(id: id)],
  );
  SceneOperation hide(String key) => SceneOperation(
    sceneId: 'scene',
    epoch: 'one',
    operationId: key,
    objectId: id,
    expectedRevision: 0,
    field: SceneField.visibility,
    visible: false,
  );
  test('file restart retains receipts and conditional author undo', () async {
    final dir = await Directory.systemTemp.createTemp('scene-durable-');
    addTearDown(() => dir.delete(recursive: true));
    DurableSceneAuthority host() => DurableSceneAuthority(
      store: FileSceneDocumentStore(File('${dir.path}/scene.json')),
      canRead: (_, _) => true,
      canWrite: (who, _, _) => who != 'viewer',
    );
    final first = host();
    await first.initialize(initial());
    await first.connect('alice').submit(hide('hide'));
    final second = host();
    await second.initialize(initial());
    final replay =
        await second.connect('alice').submit(hide('hide'))
            as SceneOperationAccepted;
    expect(replay.duplicate, isTrue);
    expect(replay.snapshot.revision, 1);
    await expectLater(
      second.connect('bob').undo(revision: 1, operationId: 'undo'),
      throwsA(isA<SceneAccessDenied>()),
    );
    await expectLater(
      second.connect('viewer').submit(hide('denied')),
      throwsA(isA<SceneAccessDenied>()),
    );
    final undone =
        await second.connect('alice').undo(revision: 1, operationId: 'undo')
            as SceneOperationAccepted;
    expect(undone.snapshot.objects[id]!.visible, isTrue);
    expect(undone.operation.undoOfRevision, 1);
    final duplicate =
        await host().connect('alice').undo(revision: 1, operationId: 'undo')
            as SceneOperationAccepted;
    expect(duplicate.duplicate, isTrue);
    expect(duplicate.snapshot.revision, 2);
    expect(
      await host()
          .connect('alice')
          .undo(revision: 1, operationId: 'stale-undo'),
      isA<SceneOperationConflict>(),
    );
    final redone =
        await host().connect('alice').undo(revision: 2, operationId: 'redo')
            as SceneOperationAccepted;
    expect(redone.snapshot.objects[id]!.visible, isFalse);
  });
  test(
    'concurrent store instances serialize and failed writes preserve ledger',
    () async {
      final dir = await Directory.systemTemp.createTemp('scene-race-');
      addTearDown(() => dir.delete(recursive: true));
      DurableSceneAuthority host() => DurableSceneAuthority(
        store: FileSceneDocumentStore(File('${dir.path}/scene')),
        canRead: (_, _) => true,
        canWrite: (_, _, _) => true,
        maxReceipts: 1,
      );
      await host().initialize(initial());
      final results = await Future.wait([
        host().connect('a').submit(hide('a')),
        host().connect('b').submit(hide('b')),
      ]);
      expect(results.whereType<SceneOperationAccepted>(), hasLength(1));
      expect(results.whereType<SceneOperationConflict>(), hasLength(1));
      final accepted = results.whereType<SceneOperationAccepted>().single;
      final principal = accepted.operation.operationId;
      await expectLater(
        host().connect(principal).undo(revision: 1, operationId: 'full'),
        throwsA(isA<SceneReceiptCapacityExceeded>()),
      );
      expect((await host().connect('a').read()).revision, 1);
      await expectLater(
        host().initialize(
          SceneSnapshot(sceneId: 'scene', epoch: 'two', objects: []),
        ),
        throwsA(isA<SceneSessionMismatch>()),
      );
    },
  );
  test('corrupt history and future schemas fail closed', () async {
    await expectLater(
      LocalSceneAuthority.restore(
        archive: '{"schemaVersion":2,"entries":[]}',
        canRead: (_, _) => true,
        canWrite: (_, _, _) => true,
      ),
      throwsFormatException,
    );
    final local = LocalSceneAuthority(
      initial: initial(),
      canRead: (_, _) => true,
      canWrite: (_, _, _) => true,
    );
    await local.connect('a').submit(hide('a'));
    final corrupted = local.exportArchive().replaceFirst(
      '"expectedRevision":0',
      '"expectedRevision":9',
    );
    await expectLater(
      LocalSceneAuthority.restore(
        archive: corrupted,
        canRead: (_, _) => true,
        canWrite: (_, _, _) => true,
      ),
      throwsFormatException,
    );
  });
}
