import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'save_replay_test.dart' as fixture;

Map<String, Object?> identity(GameSession session, {int queued = 0}) => {
  'session': session.save().encode(),
  'epoch': session.epoch,
  'revision': session.revision,
  'handles': session.entities.entities.map((e) => e.handle.toString()).toList(),
  'queued': queued,
  'fault': session.fault?.toString(),
};

void main() {
  final receipts = <String, Object?>{};
  tearDownAll(() async {
    final destination = Platform.environment['GAME_FAILURE_RECEIPT_PATH'];
    if (destination == null) return;
    final file = File(destination);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'schemaVersion': 1, 'cases': receipts}),
    );
  });

  void rejected(
    String id,
    String recovery,
    Future<void> Function(GameSession, Map<String, Object?>) check,
  ) {
    test('failure receipt $id', () async {
      final session = fixture.game()..step();
      final receipt = <String, Object?>{};
      try {
        await check(session, receipt);
        expect(receipt['before'], receipt['after']);
      } finally {
        await session.close();
      }
      expect(session.isClosed, isTrue);
      receipts[id] = {
        ...receipt,
        'status': 'passed',
        'actualStatus': 'rejected',
        'cleanupCounters': {
          'before': {'liveSessions': 0},
          'after': {'liveSessions': session.isClosed ? 0 : 1},
        },
        'recovery': {'action': recovery, 'status': 'passed'},
        'execution': {
          'kind': 'pure',
          'exitCode': 0,
          'command':
              'fvm dart --packages=.dart_tool/package_config.json '
              'packages/zyren_game/test/failure_matrix_test.dart',
        },
      };
    });
  }

  rejected('project.malformed', 'retry_valid_project', (
    session,
    receipt,
  ) async {
    receipt['before'] = identity(session);
    expect(
      () => GameProject.decode('{}', GameRegistry()),
      throwsFormatException,
    );
    receipt['after'] = identity(session);
    expect(
      GameProject.decode(
        session.project.project.encode(),
        GameRegistry(),
      ).encode(),
      session.project.project.encode(),
    );
  });
  rejected('project.oversized', 'retry_bounded_project', (
    session,
    receipt,
  ) async {
    receipt['before'] = identity(session);
    expect(
      () => GameComponentRecord('optional', 1, {
        'payload': 'x' * 65537,
      }, required: false),
      throwsFormatException,
    );
    receipt['after'] = identity(session);
    expect(
      GameComponentRecord('optional', 1, {
        'payload': 'bounded',
      }, required: false).data['payload'],
      'bounded',
    );
  });
  rejected('entity.removed', 'resolve_live_actor', (session, receipt) async {
    final actor = session.entities.entities.single.handle;
    session.entities.despawn(actor);
    receipt['before'] = identity(session);
    expect(
      session.commands.enqueue(GameCommand(actor, 2, 'move'), session.entities),
      isFalse,
    );
    receipt['after'] = identity(session);
    final fresh = session.entities.spawn(actor.id);
    expect(
      session.commands.enqueue(GameCommand(fresh, 2, 'move'), session.entities),
      isTrue,
    );
  });
  rejected('action.stale', 'refresh_actor_generation', (
    session,
    receipt,
  ) async {
    final old = session.entities.entities.single.handle;
    session.entities.despawn(old);
    final fresh = session.entities.spawn(old.id);
    receipt['before'] = identity(session);
    expect(
      session.commands.enqueue(GameCommand(old, 2, 'stale'), session.entities),
      isFalse,
    );
    receipt['after'] = identity(session);
    expect(
      session.commands.enqueue(
        GameCommand(fresh, 2, 'fresh'),
        session.entities,
      ),
      isTrue,
    );
    expect(session.commands.drain(2, session.entities).single.target, fresh);
  });
  rejected('queue.saturated', 'drain_and_retry', (session, receipt) async {
    final actor = session.entities.entities.single.handle;
    final queue = GameCommandQueue<Object>(
      limits: GameLimits(maxQueuedCommands: 1),
    );
    expect(
      queue.enqueue(GameCommand(actor, 2, 'first'), session.entities),
      isTrue,
    );
    receipt['before'] = identity(session, queued: queue.length);
    expect(
      queue.enqueue(GameCommand(actor, 2, 'overflow'), session.entities),
      isFalse,
    );
    receipt['after'] = identity(session, queued: queue.length);
    expect(queue.drain(2, session.entities).single.payload, 'first');
    expect(
      queue.enqueue(GameCommand(actor, 3, 'retry'), session.entities),
      isTrue,
    );
  });
  rejected('save.failed', 'retry_compatible_restore', (session, receipt) async {
    final codec = fixture.CounterCodec('counter');
    session.registerStateCodec(codec);
    codec.value = 2;
    final target = session.save();
    codec.value = 1;
    codec.failCommit = true;
    receipt['before'] = identity(session);
    expect(() => session.restore(target), throwsStateError);
    receipt['after'] = identity(session);
    expect(codec.value, 1);
    codec.failCommit = false;
    session.restore(target);
    expect(codec.value, 2);
  });
}
