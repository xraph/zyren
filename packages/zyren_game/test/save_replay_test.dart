import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';

GameSession game() => GameSession(
  project: CompiledGameProject(
    project: GameProject(
      id: 'g',
      startupLevel: 'l',
      levels: [
        GameLevel(
          id: 'l',
          scene: GameSceneIdentity('scene', 'pin'),
          entities: [GameEntityRecord(id: 'actor')],
        ),
      ],
      registry: GameRegistry(),
    ),
  ),
  seed: 7,
);

class CounterCodec extends GameStateCodec<int> {
  @override
  final String id;
  @override
  int get version => 1;
  int value = 1, discarded = 0;
  bool failPrepare = false, failCommit = false, failRollback = false;
  CounterCodec(this.id);
  @override
  Map<String, Object?> capture(GameSession session) => {'value': value};
  @override
  int prepare(GameSession session, Map<String, Object?> data) {
    final n = data['value'];
    if (failPrepare || n is! int || n < 0) throw StateError('invalid counter');
    return n;
  }

  @override
  void commit(GameSession session, int prepared) {
    value = prepared;
    if (failCommit && prepared == 2 || failRollback && prepared == 1) {
      throw StateError('commit failed');
    }
  }

  @override
  void discard(int prepared) {
    discarded++;
  }
}

void main() {
  test('compiled recipe round trips', () {
    final source = game().project.encode();
    expect(CompiledGameProject.decode(source, GameRegistry()).encode(), source);
  });
  test('incompatible restore leaves encoded state unchanged', () async {
    final session = game()..step();
    final before = session.save().encode();
    final json = jsonDecode(before) as Map<String, dynamic>;
    json['buildId'] = 'different';
    expect(
      () => session.restore(GameSave.decode(jsonEncode(json))),
      throwsStateError,
    );
    expect(session.save().encode(), before);
    await session.close();
  });
  test(
    'restore stages live state, advances generations and clears commands',
    () async {
      final session = game()..step();
      final codec = CounterCodec('counter');
      session.registerStateCodec(codec);
      final original = session.entities.entities.single.handle,
          saved = session.save();
      codec.value = 2;
      session.step();
      session.commands.enqueue(
        GameCommand(original, 3, 'stale'),
        session.entities,
      );
      session.restore(saved);
      expect(session.tick, 1);
      expect(codec.value, 1);
      expect(session.entities.isAlive(original), isFalse);
      expect(
        session.entities.entities.single.handle.generation,
        greaterThan(original.generation),
      );
      expect(session.commands.length, 0);
      session.step();
      expect(session.tick, 2);
      await session.close();
    },
  );
  test(
    'commit failure rolls back failing codec and runtime checkpoint',
    () async {
      final session = game()..step();
      final codec = CounterCodec('counter');
      session.registerStateCodec(codec);
      codec.value = 2;
      final target = session.save();
      codec.value = 1;
      codec.failCommit = true;
      final before = session.save().encode(),
          actor = session.entities.entities.single.handle;
      expect(() => session.restore(target), throwsStateError);
      expect(session.save().encode(), before);
      expect(session.entities.isAlive(actor), isTrue);
      expect(session.fault, isNull);
      await session.close();
    },
  );
  test('later prepare failure discards already prepared candidates', () async {
    final session = game()..step();
    final first = CounterCodec('first'), second = CounterCodec('second');
    session.registerStateCodec(first);
    session.registerStateCodec(second);
    final target = session.save();
    second.failPrepare = true;
    final before = session.save().encode();
    expect(() => session.restore(target), throwsStateError);
    expect(first.discarded, greaterThan(0));
    expect(session.save().encode(), before);
    await session.close();
  });
  test('rollback failure becomes a visible fault', () async {
    final session = game()..step();
    final codec = CounterCodec('counter');
    session.registerStateCodec(codec);
    codec.value = 2;
    final target = session.save();
    codec.value = 1;
    codec.failCommit = true;
    codec.failRollback = true;
    expect(() => session.restore(target), throwsStateError);
    expect(session.fault, isNotNull);
    expect(session.paused, isTrue);
    await session.close();
  });
  test('missing codec and model pin fail before mutation', () async {
    final session = game()..step();
    final lease = session.registerStateCodec(CounterCodec('counter'));
    final target = session.save();
    lease.cancel();
    final before = session.save().encode();
    expect(() => session.restore(target), throwsStateError);
    expect(session.save().encode(), before);
    final json = target.toJson()..['models'] = {'brain': 'wrong'};
    expect(
      () => session.restore(GameSave.decode(jsonEncode(json))),
      throwsStateError,
    );
    await session.close();
  });
  test('schema migration is explicit and bounded', () {
    final legacy = game().save().toJson()..['schemaVersion'] = 1;
    expect(() => GameSave.decode(jsonEncode(legacy)), throwsFormatException);
    final migrated = GameSave.decode(
      jsonEncode(legacy),
      migrations: {
        1: (json) => {...json, 'schemaVersion': 2},
      },
    );
    expect(migrated.schemaVersion, 2);
  });
}
