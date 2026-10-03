import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'support/native_game_fixture.dart';

class NoAssets implements GameAssetResolver {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No assets requested.');
}

class WorldOwner extends GameSystem {
  final PhysicsWorld world;
  final bool fail;
  static int live = 0;
  WorldOwner(this.world, {this.fail = false}) {
    live++;
  }
  @override
  String get id => 'fixture.world-owner';
  @override
  GamePhase get phase => GamePhase.commands;
  @override
  void start(GameSession session) {
    if (fail) throw StateError('partial native setup');
  }

  @override
  void fixedUpdate(GameSession session) {}
  @override
  void dispose(GameSession session) {
    if (!world.isClosed) {
      world.close();
      live--;
    }
  }
}

void main() {
  test(
    'real native world fifty-cycle lifetime and failed preparation return to baseline',
    () async {
      final baseline = WorldOwner.live;
      var fail = false;
      final worlds = <PhysicsWorld>[];
      final manager = GameLevelManager(
        project: testProject(),
        resolver: NoAssets(),
        seed: 1,
        systems: (_) {
          final world = PhysicsWorld();
          worlds.add(world);
          final body = world.createBody();
          body.addCollider(const SphereShape(.25));
          final physics = PhysicsPlugin(
            world: world,
            externallyDriven: true,
            interpolate: false,
          );
          return [WorldOwner(world, fail: fail), GamePhysicsDriver(physics)];
        },
      );
      try {
        for (var cycle = 0; cycle < 50; cycle++) {
          final session = await manager.load('level', capabilities: {});
          session.step();
          expect(WorldOwner.live, baseline + 1);
          await manager.unload();
          expect(WorldOwner.live, baseline);
          expect(worlds.last.isClosed, isTrue);
        }
        final active = await manager.load('level', capabilities: {});
        fail = true;
        await expectLater(
          manager.load('level', capabilities: {}),
          throwsStateError,
        );
        expect(manager.session, same(active));
        expect(WorldOwner.live, baseline + 1);
        expect(worlds.last.isClosed, isTrue);
      } finally {
        await manager.close();
      }
      expect(WorldOwner.live, baseline);
      expect(worlds.every((w) => w.isClosed), isTrue);
    },
  );
}
