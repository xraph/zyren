import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'save_replay_test.dart' as fixture;

class Lease implements GameAssetLease {
  @override
  final Uint8List bytes;
  final void Function() release;
  bool closed = false;
  Lease(this.bytes, this.release);
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    release();
  }
}

class Assets implements GameAssetResolver {
  int live = 0;
  bool mismatch = false;
  Completer<void>? gate;
  @override
  Future<GameAssetLease> load(
    GameAssetReference ref,
    LoadCancellation cancellation,
  ) async {
    await gate?.future;
    live++;
    return Lease(Uint8List.fromList(mismatch ? [9] : [1]), () => live--);
  }
}

class NativeOwner extends GameSystem {
  static int live = 0;
  final bool fail;
  NativeOwner(this.fail);
  @override
  String get id => 'native.fixture';
  @override
  GamePhase get phase => GamePhase.physics;
  @override
  void start(GameSession session) {
    live++;
    if (fail) throw StateError('partial native init');
  }

  @override
  void fixedUpdate(GameSession session) {}
  @override
  void dispose(GameSession session) {
    live--;
  }
}

class SlowDispose extends GameSystem {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  @override
  String get id => 'slow.dispose';
  @override
  GamePhase get phase => GamePhase.physics;
  @override
  void fixedUpdate(GameSession session) {}
  @override
  Future<void> dispose(GameSession session) async {
    entered.complete();
    await release.future;
  }
}

CompiledGameProject project() {
  final digest = sha256.convert([1]).toString();
  return CompiledGameProject(
    project: fixture.game().project.project,
    assets: [
      GameAssetReference(
        id: 'asset',
        revision: 'pin',
        uri: Uri.parse('game:///a'),
        digest: digest,
      ),
    ],
    artifactHashes: {'asset': digest},
  );
}

void main() {
  test(
    'unload closes already prepared candidates without caller cleanup',
    () async {
      final assets = Assets();
      final manager = GameLevelManager(
        project: project(),
        resolver: assets,
        seed: 7,
        systems: (_) => [NativeOwner(false)],
      );
      final candidate = await manager.prepare('l');
      expect(assets.live, 1);
      await manager.unload();
      expect(assets.live, 0);
      expect(NativeOwner.live, 0);
      expect(manager.preparedCount, 0);
      expect(candidate.session.isClosed, isTrue);
      await manager.close();
    },
  );
  test(
    'unload during activation cleanup cannot return a closed load',
    () async {
      final assets = Assets();
      final old = SlowDispose();
      var first = true;
      final manager = GameLevelManager(
        project: project(),
        resolver: assets,
        seed: 7,
        systems: (_) {
          if (first) {
            first = false;
            return [old];
          }
          return [];
        },
      );
      await manager.load('l', capabilities: {});
      final pending = manager.load('l', capabilities: {});
      final rejected = expectLater(pending, throwsA(isA<LoadCancelled>()));
      await old.entered.future;
      await manager.unload();
      old.release.complete();
      await rejected;
      expect(manager.session, isNull);
      expect(assets.live, 0);
      await manager.close();
    },
  );
  test(
    'closed or superseded prepared levels cannot retain ownership',
    () async {
      final assets = Assets();
      final manager = GameLevelManager(
        project: project(),
        resolver: assets,
        seed: 7,
        systems: (_) => [],
      );
      for (var i = 0; i < 3; i++) {
        final candidate = await manager.prepare('l');
        await candidate.close();
        expect(manager.preparedCount, 0);
      }
      final older = await manager.prepare('l');
      older.validateCapabilities({});
      final newer = await manager.prepare('l');
      await expectLater(manager.activate(older), throwsStateError);
      expect(older.session.isClosed, isTrue);
      expect(assets.live, 1);
      await older.close();
      await newer.close();
      await manager.close();
      expect(assets.live, 0);
    },
  );
  test('fifty load/unload cycles return resource counts to baseline', () async {
    final assets = Assets();
    final baseline = NativeOwner.live;
    final manager = GameLevelManager(
      project: project(),
      resolver: assets,
      seed: 7,
      systems: (_) => [NativeOwner(false)],
    );
    for (var i = 0; i < 50; i++) {
      await manager.load('l', capabilities: {});
      expect(assets.live, 1);
      expect(NativeOwner.live, baseline + 1);
      await manager.unload();
      expect(assets.live, 0);
      expect(NativeOwner.live, baseline);
    }
    await manager.close();
    await manager.close();
  });
  test(
    'interrupted load, hash mismatch and partial init preserve active level',
    () async {
      final assets = Assets();
      var fail = false;
      final manager = GameLevelManager(
        project: project(),
        resolver: assets,
        seed: 7,
        systems: (_) => [NativeOwner(fail)],
      );
      final original = await manager.load('l', capabilities: {});
      assets.mismatch = true;
      await expectLater(manager.load('l', capabilities: {}), throwsStateError);
      expect(manager.session, same(original));
      expect(assets.live, 1);
      assets.mismatch = false;
      fail = true;
      await expectLater(manager.load('l', capabilities: {}), throwsStateError);
      expect(manager.session, same(original));
      expect(assets.live, 1);
      expect(NativeOwner.live, 1);
      fail = false;
      assets.gate = Completer<void>();
      final pending = manager.prepare('l');
      final rejected = expectLater(pending, throwsA(isA<LoadCancelled>()));
      await manager.unload();
      assets.gate!.complete();
      await rejected;
      expect(assets.live, 0);
      expect(NativeOwner.live, 0);
      await manager.close();
    },
  );
  test(
    'pool reset retires native handles input beliefs and component state',
    () async {
      final session = fixture.game()..step();
      final actor = session.entities.entities.single.handle;
      var handles = 1, beliefs = 1, input = 1;
      final pool = GamePool(
        entities: session.entities,
        reset: (_) {
          handles = 0;
          beliefs = 0;
          input = 0;
        },
      );
      final saved = session.save();
      expect(pool.retire(actor), isTrue);
      final next = pool.acquire(actor.id, components: []);
      expect(next.generation, greaterThan(actor.generation));
      expect([handles, beliefs, input], [0, 0, 0]);
      session.restore(saved);
      expect(session.entities.isAlive(next), isFalse);
      await session.close();
    },
  );
  test(
    'play and training admit equal replay logs for one build and seed',
    () async {
      final play = fixture.game()..step(), training = fixture.game()..step();
      final p = GameReplay(buildId: play.project.buildId, seed: play.seed),
          t = GameReplay(
            buildId: training.project.buildId,
            seed: training.seed,
          );
      for (final pair in [(play, p), (training, t)]) {
        final actor = pair.$1.entities.entities.single.handle;
        expect(
          pair.$2.accept(pair.$1, GameCommand(actor, 2, {'move': 1})),
          isTrue,
        );
        pair.$1.step();
      }
      expect(p.encode(), t.encode());
      final replayed = fixture.game();
      GameReplay.decode(p.encode()).enqueue(replayed);
      replayed.step();
      replayed.step();
      expect(replayed.tick, play.tick);
      await play.close();
      await training.close();
      await replayed.close();
    },
  );
}
