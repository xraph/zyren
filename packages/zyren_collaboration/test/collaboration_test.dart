import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';
import '../example/two_clients.dart' show LoseOneReply;
import '../../zyren/test/support/fakes.dart';

final part = SceneObjectId(source: 'assembly', key: 'part');
final other = SceneObjectId(source: 'other-assembly', key: 'part');
SceneSnapshot seed() => SceneSnapshot(
  sceneId: 'scene',
  epoch: 'epoch-1',
  objects: [
    SceneObjectState(id: part),
    SceneObjectState(id: other),
  ],
);
LocalSceneAuthority authority({int capacity = 4096}) => LocalSceneAuthority(
  initial: seed(),
  maxReceipts: capacity,
  canRead: (principal, _) => principal != 'blocked',
  canWrite: (principal, _, _) => principal == 'alice' || principal == 'bob',
);
SceneCollaborationClient client(
  SceneOperationTransport transport,
  String name,
) {
  var sequence = 0;
  return SceneCollaborationClient(
    transport: transport,
    sceneId: 'scene',
    epoch: 'epoch-1',
    nextOperationId: () => '$name-${++sequence}',
  );
}

SceneOperation move(
  String id,
  double x, {
  int expected = 0,
  SceneObjectId? target,
}) => SceneOperation(
  sceneId: 'scene',
  epoch: 'epoch-1',
  operationId: id,
  objectId: target ?? part,
  expectedRevision: expected,
  field: SceneField.transform,
  transform: SceneTransform(position: Vec3(x, 0, 0)),
);

final class ControlledTransport implements SceneOperationTransport {
  final SceneOperationTransport delegate;
  Completer<void>? readGate, submitGate;
  SceneSnapshot? readOverride;
  SceneOperationResult? resultOverride;
  bool failBeforeCommit = false;
  ControlledTransport(this.delegate);
  @override
  Future<SceneSnapshot> read() async {
    final result = readOverride ?? await delegate.read();
    await readGate?.future;
    return result;
  }

  @override
  Future<SceneOperationResult> submit(SceneOperation operation) async {
    await submitGate?.future;
    if (failBeforeCommit) throw TimeoutException('offline');
    return resultOverride ?? await delegate.submit(operation);
  }
}

void main() {
  test(
    'source namespace prevents collisions and snapshot encoding is canonical',
    () {
      final snapshot = seed();
      expect(snapshot.objects.length, 2);
      expect(SceneObjectId(source: 'assembly', key: 'part'), part);
      final reordered = SceneSnapshot(
        sceneId: 'scene',
        epoch: 'epoch-1',
        objects: snapshot.objects.values.toList().reversed,
      );
      expect(reordered.encode(), snapshot.encode());
      expect(
        SceneSnapshot.decode(snapshot.encode()).encode(),
        snapshot.encode(),
      );
      expect(
        () => SceneSnapshot(
          sceneId: 'scene',
          epoch: 'x',
          objects: [
            SceneObjectState(id: part),
            SceneObjectState(id: part),
          ],
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'payloads reject unsupported schemas, malformed values and size overruns',
    () {
      final encoded = move('m', 2).encode();
      expect(SceneOperation.decode(encoded).encode(), encoded);
      for (final patch in [
        {'schemaVersion': 2},
        {'expectedRevision': 0.5},
        {'expectedRevision': -1},
        {'field': 'physics'},
        {'value': true},
        {'operationId': ''},
      ]) {
        final json = jsonDecode(encoded) as Map<String, dynamic>;
        json.addAll(patch);
        expect(
          () => SceneOperation.decode(jsonEncode(json)),
          throwsFormatException,
        );
      }
      expect(
        () => SceneOperation.decode(' ' * (SceneOperation.maxCharacters + 1)),
        throwsFormatException,
      );
      expect(
        () => SceneSnapshot.decode(' ' * (SceneSnapshot.maxCharacters + 1)),
        throwsFormatException,
      );
      expect(
        () => SceneTransform(position: Vec3(double.nan, 0, 0)),
        throwsArgumentError,
      );
      expect(() => SceneTransform(scale: Vec3.zero), throwsArgumentError);
      expect(
        () => SceneTransform(rotation: const Quat(0, 0, 0, 0)),
        throwsArgumentError,
      );
      expect(
        () => SceneSnapshot(
          sceneId: 's',
          epoch: 'e',
          objects: [SceneObjectState(id: part, transformRevision: 1)],
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'two clients merge independent fields without overwriting transforms',
    () async {
      final server = authority();
      final alice = client(server.connect('alice'), 'a');
      final bob = client(server.connect('bob'), 'b');
      addTearDown(alice.close);
      addTearDown(bob.close);
      await Future.wait([alice.refresh(), bob.refresh()]);
      alice.setTransform(part, SceneTransform(position: const Vec3(3, 4, 5)));
      bob.setVisible(part, false);
      final results = await Future.wait([alice.flush(), bob.flush()]);
      expect(results, everyElement(isA<SceneOperationAccepted>()));
      await Future.wait([alice.refresh(), bob.refresh()]);
      expect(alice.snapshot!.encode(), bob.snapshot!.encode());
      expect(alice.snapshot!.objects[part]!.visible, isFalse);
      expect(
        alice.snapshot!.objects[part]!.transform.position,
        const Vec3(3, 4, 5),
      );
      expect(alice.snapshot!.revision, 2);
    },
  );

  test(
    'same-field conflict preserves intent and stale explicit decisions conflict again',
    () async {
      final server = authority();
      final a = client(server.connect('alice'), 'a'),
          b = client(server.connect('bob'), 'b');
      addTearDown(a.close);
      addTearDown(b.close);
      await Future.wait([a.refresh(), b.refresh()]);
      a.setTransform(part, SceneTransform(position: const Vec3(1, 0, 0)));
      b.setTransform(part, SceneTransform(position: const Vec3(2, 0, 0)));
      await a.flush();
      final conflict = await b.flush() as SceneOperationConflict;
      expect(conflict.actualRevision, 1);
      expect(b.pending!.transform!.position.x, 2);
      expect(b.snapshot!.objects[part]!.transform.position.x, 1);
      a.setTransform(part, SceneTransform(position: const Vec3(3, 0, 0)));
      await a.flush();
      b.keepLocal();
      expect(b.pending!.expectedRevision, 1);
      expect(await b.flush(), isA<SceneOperationConflict>());
      b.keepLocal();
      expect(await b.flush(), isA<SceneOperationAccepted>());
      await a.refresh();
      expect(a.snapshot!.objects[part]!.transform.position.x, 2);
      expect(a.snapshot!.revision, 3);
    },
  );

  test('accepting remote explicitly clears a confirmed conflict', () async {
    final server = authority();
    final b = client(server.connect('bob'), 'b');
    addTearDown(b.close);
    await b.refresh();
    b.setTransform(part, SceneTransform());
    await server.connect('alice').submit(move('a', 4));
    await b.flush();
    b.acceptRemote();
    expect(b.pending, isNull);
    expect(b.conflict, isNull);
    expect(b.snapshot!.objects[part]!.transform.position.x, 4);
  });

  test(
    'lost reply retries once and cannot roll back a newer remote edit',
    () async {
      final server = authority();
      final link = server.connect('alice');
      final a = client(LoseOneReply(link), 'a');
      addTearDown(a.close);
      await a.refresh();
      final pending = a.setTransform(
        part,
        SceneTransform(position: const Vec3(1, 0, 0)),
      );
      await expectLater(a.flush(), throwsA(isA<TimeoutException>()));
      expect(a.pending, same(pending));
      expect(() => a.acceptRemote(), throwsStateError);
      await server.connect('bob').submit(move('b', 2, expected: 1));
      final receipt = await a.flush() as SceneOperationAccepted;
      expect(receipt.duplicate, isTrue);
      expect(receipt.committedRevision, 1);
      expect(a.snapshot!.revision, 2);
      expect(a.snapshot!.objects[part]!.transform.position.x, 2);
      expect(a.pending, isNull);
      await expectLater(
        link.submit(move(pending.operationId, 5)),
        throwsStateError,
      );
    },
  );

  test('failure before commit retains intent and retry recovers', () async {
    final server = authority();
    final transport = ControlledTransport(server.connect('alice'));
    final a = client(transport, 'a');
    addTearDown(a.close);
    await a.refresh();
    a.setVisible(part, false);
    transport.failBeforeCommit = true;
    await expectLater(a.flush(), throwsA(isA<TimeoutException>()));
    expect((await server.connect('bob').read()).revision, 0);
    expect(a.pending, isNotNull);
    expect(a.isBusy, isFalse);
    transport.failBeforeCommit = false;
    await a.flush();
    expect(a.snapshot!.revision, 1);
  });

  test(
    'read and write permission checks apply to retries after revocation',
    () async {
      var writable = true;
      final server = LocalSceneAuthority(
        initial: seed(),
        canRead: (principal, _) => principal != 'blocked',
        canWrite: (principal, _, _) => principal == 'alice' && writable,
      );
      final link = server.connect('alice');
      final op = move('1', 2);
      await link.submit(op);
      writable = false;
      await expectLater(link.submit(op), throwsA(isA<SceneAccessDenied>()));
      expect(await link.allows(op), isFalse);
      await expectLater(
        server.connect('reader').submit(move('x', 3)),
        throwsA(isA<SceneAccessDenied>()),
      );
      await expectLater(
        server.connect('blocked').read(),
        throwsA(isA<SceneAccessDenied>()),
      );
      await expectLater(
        server.connect('blocked').history(expectedRevision: 1),
        throwsA(isA<SceneAccessDenied>()),
      );
      expect((await link.read()).revision, 1);
    },
  );

  test('async permission checks serialize competing writers', () async {
    final gate = Completer<void>();
    var checked = 0;
    final server = LocalSceneAuthority(
      initial: seed(),
      canRead: (_, _) => true,
      canWrite: (_, _, _) async {
        checked++;
        await gate.future;
        return true;
      },
    );
    final a = server.connect('alice').submit(move('a', 1));
    final b = server.connect('bob').submit(move('b', 2));
    await Future<void>.delayed(Duration.zero);
    expect(checked, 1);
    gate.complete();
    expect(await a, isA<SceneOperationAccepted>());
    expect(await b, isA<SceneOperationConflict>());
    expect((await server.connect('alice').read()).revision, 1);
  });

  test('permission failures release the queue', () async {
    var fail = true;
    final server = LocalSceneAuthority(
      initial: seed(),
      canRead: (_, _) {
        if (fail) throw StateError('policy unavailable');
        return true;
      },
      canWrite: (_, _, _) => true,
    );
    final link = server.connect('alice');
    await expectLater(link.read(), throwsStateError);
    fail = false;
    expect((await link.read()).revision, 0);
  });

  test(
    'full receipt capacity rejects new edits but retains retry and history',
    () async {
      final link = authority(capacity: 1).connect('alice');
      final op = move('a', 1);
      await link.submit(op);
      await expectLater(
        link.submit(move('b', 2, expected: 1)),
        throwsA(isA<SceneReceiptCapacityExceeded>()),
      );
      expect(
        (await link.submit(op) as SceneOperationAccepted).duplicate,
        isTrue,
      );
      expect((await link.history(expectedRevision: 1)).records.length, 1);
    },
  );

  test('history is paginated and rejects stale revision queries', () async {
    final link = authority().connect('alice');
    await link.submit(move('a', 1));
    await link.submit(move('b', 2, expected: 1));
    final first = await link.history(expectedRevision: 2, limit: 1);
    expect(first.records.single.revision, 1);
    expect(first.nextAfterRevision, 1);
    final next = await link.history(
      expectedRevision: 2,
      afterRevision: first.nextAfterRevision!,
    );
    expect(next.records.single.revision, 2);
    expect(next.nextAfterRevision, isNull);
    await expectLater(
      link.history(expectedRevision: 1),
      throwsA(isA<SceneRevisionMismatch>()),
    );
    await expectLater(
      link.history(expectedRevision: 2, limit: 101),
      throwsArgumentError,
    );
  });

  test('scene epoch mismatch and unknown targets never commit', () async {
    final link = authority().connect('alice');
    final data = jsonDecode(move('a', 1).encode()) as Map<String, dynamic>;
    data['epoch'] = 'discarded-epoch';
    await expectLater(
      link.submit(SceneOperation.decode(jsonEncode(data))),
      throwsA(isA<SceneSessionMismatch>()),
    );
    await expectLater(
      link.submit(
        move(
          'b',
          2,
          target: SceneObjectId(source: 'x', key: 'x'),
        ),
      ),
      throwsStateError,
    );
    expect((await link.read()).revision, 0);
  });

  test(
    'client rejects wrong and inconsistent receipts without dropping pending edit',
    () async {
      final transport = ControlledTransport(authority().connect('alice'));
      final a = client(transport, 'a');
      addTearDown(a.close);
      await a.refresh();
      final op = a.setTransform(
        part,
        SceneTransform(position: const Vec3(1, 0, 0)),
      );
      transport.resultOverride = SceneOperationAccepted(
        operation: move('foreign', 1),
        snapshot: seed(),
        committedRevision: 1,
      );
      await expectLater(a.flush(), throwsStateError);
      expect(a.pending, same(op));
      transport.resultOverride = SceneOperationAccepted(
        operation: op,
        snapshot: seed(),
        committedRevision: 1,
      );
      await expectLater(a.flush(), throwsStateError);
      expect(a.pending, same(op));
      transport.resultOverride = null;
      await a.flush();
    },
  );

  test(
    'stale snapshots cannot regress the client and requests cannot overlap',
    () async {
      final transport = ControlledTransport(authority().connect('alice'));
      final a = client(transport, 'a');
      addTearDown(a.close);
      await a.refresh();
      a.setVisible(part, false);
      await a.flush();
      transport.readOverride = seed();
      transport.readGate = Completer<void>();
      final read = a.refresh();
      await expectLater(a.refresh(), throwsStateError);
      expect(() => a.setVisible(part, true), throwsStateError);
      transport.readGate!.complete();
      await read;
      expect(a.snapshot!.revision, 1);
      expect(a.snapshot!.objects[part]!.visible, isFalse);
    },
  );

  test(
    'closing during a request prevents late client state mutation',
    () async {
      final transport = ControlledTransport(authority().connect('alice'));
      final a = client(transport, 'a');
      await a.refresh();
      a.setVisible(part, false);
      transport.submitGate = Completer<void>();
      final write = a.flush();
      final rejected = expectLater(write, throwsStateError);
      await a.close();
      transport.submitGate!.complete();
      await rejected;
      expect(a.snapshot!.revision, 0);
      expect(a.pending, isNotNull);
    },
  );

  test(
    'scene bindings use source IDs, survive reload and stop after disposal',
    () async {
      final server = authority();
      final a = client(server.connect('alice'), 'a');
      addTearDown(a.close);
      await a.refresh();
      final scene = Scene(), foreign = Group();
      final one = scene.add(Group(name: 'Same name')),
          two = scene.add(Group(name: 'Same name'));
      var invalidations = 0;
      final binding = SceneCollaborationBinding(
        scene: scene,
        client: a,
        invalidate: () => invalidations++,
      );
      binding.rebind({part: one, other: two});
      a.setTransform(part, SceneTransform(position: const Vec3(7, 0, 0)));
      await a.flush();
      expect(one.position.x, 7);
      expect(two.position, Vec3.zero);
      expect(invalidations, 1);
      await a.refresh();
      expect(invalidations, 1);
      expect(() => binding.rebind({part: foreign}), throwsArgumentError);
      expect(binding.objectFor(part), same(one));
      scene.remove(one);
      final replacement = scene.add(Group(name: 'Renamed'));
      binding.rebind({part: replacement, other: two});
      expect(replacement.position.x, 7);
      final newParent = scene.add(Group());
      newParent.add(replacement);
      expect(binding.objectFor(part), isNull);
      expect(binding.unboundIds, contains(part));
      binding.rebind({part: replacement, other: two});
      await binding.dispose();
      await server.connect('bob').submit(move('b', 8, expected: 1));
      await a.refresh();
      expect(replacement.position.x, 7);
    },
  );

  test(
    'plugin detachment during refresh removes all scene listeners',
    () async {
      final server = authority();
      final transport = ControlledTransport(server.connect('alice'));
      final a = client(transport, 'a');
      addTearDown(a.close);
      await a.refresh();
      final scene = Scene(), renderer = TestRenderer([]);
      final object = scene.add(Group());
      final plugin = SceneCollaborationPlugin(a);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => renderer,
        plugins: [plugin],
      );
      plugin.binding.rebind({part: object});
      await server.connect('bob').submit(move('b', 5));
      transport.readGate = Completer<void>();
      final read = a.refresh();
      await engine.dispose();
      transport.readGate!.complete();
      await read;
      expect(object.position, Vec3.zero);
      expect(renderer.renders, 0);
      expect(() => plugin.binding, throwsStateError);
      expect(a.isClosed, isFalse);
    },
  );
}
