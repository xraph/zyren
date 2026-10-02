import 'dart:async';
import 'package:zyren/zyren.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';

/// Drops a reply after commit, so the client cannot know whether the edit applied.
final class LoseOneReply implements SceneOperationTransport {
  final SceneOperationTransport delegate;
  bool drop = true;
  LoseOneReply(this.delegate);
  @override
  Future<SceneSnapshot> read() => delegate.read();
  @override
  Future<SceneOperationResult> submit(SceneOperation operation) async {
    final result = await delegate.submit(operation);
    if (drop) {
      drop = false;
      throw TimeoutException('Example: committed reply was lost.');
    }
    return result;
  }
}

Future<void> main() async {
  final id = SceneObjectId(source: 'demo-assembly', key: 'housing');
  final authority = LocalSceneAuthority(
    initial: SceneSnapshot(
      sceneId: 'local-demo',
      epoch: 'demo-run-1',
      objects: [SceneObjectState(id: id)],
    ),
    canRead: (principal, _) => {'alice', 'bob'}.contains(principal),
    canWrite: (principal, _, _) => {'alice', 'bob'}.contains(principal),
  );
  var sequence = 0;
  SceneCollaborationClient connect(String principal, {bool loseReply = false}) {
    final transport = authority.connect(principal);
    return SceneCollaborationClient(
      transport: loseReply ? LoseOneReply(transport) : transport,
      sceneId: 'local-demo',
      epoch: 'demo-run-1',
      nextOperationId: () => '$principal-${++sequence}',
    );
  }

  final alice = connect('alice', loseReply: true), bob = connect('bob');
  final aliceScene = Scene(), bobScene = Scene();
  final aliceObject = aliceScene.add(Group(name: 'Housing'));
  final bobObject = bobScene.add(Group(name: 'Housing'));
  final aliceView = SceneCollaborationBinding(scene: aliceScene, client: alice);
  final bobView = SceneCollaborationBinding(scene: bobScene, client: bob);
  try {
    await Future.wait([alice.refresh(), bob.refresh()]);
    aliceView.rebind({id: aliceObject});
    bobView.rebind({id: bobObject});
    alice.setTransform(id, SceneTransform(position: const Vec3(1, 0, 0)));
    bob.setTransform(id, SceneTransform(position: const Vec3(2, 0, 0)));
    try {
      await alice.flush();
    } on TimeoutException {
      print('Lost reply: exact edit retained for retry.');
    }
    final retry = await alice.flush() as SceneOperationAccepted;
    print(
      'Retry receipt: duplicate=${retry.duplicate}, revision=${retry.committedRevision}.',
    );
    final conflict = await bob.flush() as SceneOperationConflict;
    print(
      'Bob conflict: expected=${conflict.operation.expectedRevision}, current=${conflict.actualRevision}.',
    );
    bob.keepLocal();
    await bob.flush();
    await alice.refresh();
    if (aliceObject.position != const Vec3(2, 0, 0) ||
        aliceObject.position != bobObject.position ||
        alice.snapshot!.revision != 2) {
      throw StateError('The scene graphs did not converge.');
    }
    print(
      'Both scene graphs: x=${aliceObject.position.x}, revision=${alice.snapshot!.revision}.',
    );
  } finally {
    await aliceView.dispose();
    await bobView.dispose();
    await alice.close();
    await bob.close();
  }
}
