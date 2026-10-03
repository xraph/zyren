import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';

GameSession makeSession() => GameSession(
  project: CompiledGameProject(
    project: GameProject(
      id: 'p',
      startupLevel: 'l',
      levels: [
        GameLevel(id: 'l', scene: GameSceneIdentity('s', 'pin'), entities: []),
      ],
      registry: GameRegistry(),
    ),
  ),
  seed: 1,
)..step();

void main() {
  test(
    'same seat is idempotent and rejected policies preserve old authority',
    () async {
      final session = makeSession();
      addTearDown(session.close);
      final host = GamePossession(session);
      addTearDown(host.close);
      final actor = session.entities.spawn('actor');
      final target = session.entities.spawn('target');
      var acquired = 0, released = 0;
      host.registerSeat(
        GamePossessionSeat(
          id: 'a',
          target: target,
          canReach: (_) => true,
          canExit: (_) => false,
          acquireControl: (_) {
            acquired++;
            return GamePossessionControl(
              isActive: () => true,
              release: () => released++,
            );
          },
        ),
      );
      expect(host.transfer(actor, 'a'), isTrue);
      expect(host.transfer(actor, 'a'), isTrue);
      expect(acquired, 1);
      expect(host.transfer(actor, null), isFalse);
      expect(released, 0);
      expect(host.seatOf(actor), 'a');
    },
  );
  test(
    'failed revalidation releases proposed and invalidated old authority',
    () async {
      final session = makeSession();
      addTearDown(session.close);
      final host = GamePossession(session);
      addTearDown(host.close);
      final actor = session.entities.spawn('actor'),
          target = session.entities.spawn('target');
      var oldActive = false, proposedActive = false, released = 0;
      host.registerSeat(
        GamePossessionSeat(
          id: 'a',
          target: target,
          canReach: (_) => true,
          canExit: (_) => true,
          acquireControl: (_) {
            oldActive = true;
            return GamePossessionControl(
              isActive: () => oldActive,
              release: () {
                oldActive = false;
                released++;
              },
            );
          },
        ),
      );
      host.registerSeat(
        GamePossessionSeat(
          id: 'b',
          target: target,
          canReach: (_) => true,
          canExit: (_) => true,
          acquireControl: (_) {
            oldActive = false;
            proposedActive = true;
            session.entities.despawn(target);
            return GamePossessionControl(
              isActive: () => proposedActive,
              release: () {
                proposedActive = false;
                released++;
              },
            );
          },
        ),
      );
      expect(host.transfer(actor, 'a'), isTrue);
      expect(host.transfer(actor, 'b'), isFalse);
      expect(oldActive || proposedActive, isFalse);
      expect(host.seatOf(actor), isNull);
      expect(released, 2);
    },
  );
  test('active lease callback cannot commit a disappearing target', () async {
    final session = makeSession();
    addTearDown(session.close);
    final host = GamePossession(session);
    addTearDown(host.close);
    final actor = session.entities.spawn('actor'),
        target = session.entities.spawn('target');
    var released = false;
    host.registerSeat(
      GamePossessionSeat(
        id: 'a',
        target: target,
        canReach: (_) => true,
        canExit: (_) => true,
        acquireControl: (_) => GamePossessionControl(
          isActive: () {
            session.entities.despawn(target);
            return true;
          },
          release: () => released = true,
        ),
      ),
    );
    expect(host.transfer(actor, 'a'), isFalse);
    expect(released, isTrue);
    expect(host.seatOf(actor), isNull);
  });
  test(
    'generation and pause invalidate occupants and reject stale handles',
    () async {
      final session = makeSession();
      addTearDown(session.close);
      final host = GamePossession(session);
      addTearDown(host.close);
      final actor = session.entities.spawn('actor'),
          target = session.entities.spawn('target');
      var active = true;
      host.registerSeat(
        GamePossessionSeat(
          id: 'a',
          target: target,
          canReach: (_) => true,
          canExit: (_) => true,
          acquireControl: (_) => GamePossessionControl(
            isActive: () => active,
            release: () => active = false,
          ),
        ),
      );
      expect(host.transfer(actor, 'a'), isTrue);
      session.pause();
      expect(active, isFalse);
      expect(host.occupant('a'), isNull);
      session.resume();
      session.entities.despawn(actor);
      session.entities.spawn('actor');
      expect(host.transfer(actor, 'a'), isFalse);
    },
  );
}
