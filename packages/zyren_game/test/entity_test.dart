import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';

void main() {
  test('despawn invalidates old handle and respawn increments generation', () {
    final table = GameEntityTable();
    final old = table.spawn('guard');
    expect(table.despawn(old), isTrue);
    final next = table.spawn('guard');
    expect(next.generation, old.generation + 1);
    expect(table.isAlive(old), isFalse);
    expect(table.isAlive(next), isTrue);
    expect(table.despawn(old), isFalse);
    expect(table.isAlive(next), isTrue);
    expect(GameEntityHandle(next.id, next.generation), next);
  });
  test('duplicate spawns and bounded live entities leave table unchanged', () {
    final table = GameEntityTable(limits: GameLimits(maxEntities: 1));
    final first = table.spawn('a');
    expect(() => table.spawn('a'), throwsStateError);
    expect(() => table.spawn('b'), throwsStateError);
    expect(table.length, 1);
    expect(table.isAlive(first), isTrue);
    table.despawn(first);
    expect(table.spawn('b').id, 'b');
    expect(table.isAlive(first), isFalse);
  });
  test('entity components and table snapshots are immutable', () {
    final table = GameEntityTable();
    final components = [GameComponentRecord('game.test', 1, {})];
    final handle = table.spawn('a', components: components);
    components.clear();
    expect(table.entity(handle)!.components.length, 1);
    expect(
      () => table.entity(handle)!.components.clear(),
      throwsUnsupportedError,
    );
    final snapshot = table.entities;
    table.despawn(handle);
    expect(snapshot.length, 1);
    expect(table.entities, isEmpty);
  });
  test(
    'typed commands reject stale handles at admission and at application',
    () {
      final table = GameEntityTable();
      final old = table.spawn('guard');
      final queue = GameCommandQueue<String>();
      expect(queue.enqueue(GameCommand(old, 1, 'move'), table), isTrue);
      table.despawn(old);
      final next = table.spawn('guard');
      expect(queue.enqueue(GameCommand(old, 1, 'stale'), table), isFalse);
      expect(queue.enqueue(GameCommand(next, 1, 'current'), table), isTrue);
      final applied = queue.drain(1, table);
      expect(applied.map((c) => c.payload), ['current']);
      expect(applied.single.target, next);
      expect(queue.length, 0);
    },
  );
  test('queue is bounded, preserves tick order and discards missed ticks', () {
    final table = GameEntityTable();
    final handle = table.spawn('a');
    final queue = GameCommandQueue<String>(
      limits: GameLimits(maxQueuedCommands: 3),
    );
    expect(queue.enqueue(GameCommand(handle, 2, 'future'), table), isTrue);
    expect(queue.enqueue(GameCommand(handle, 1, 'first'), table), isTrue);
    expect(queue.enqueue(GameCommand(handle, 1, 'second'), table), isTrue);
    expect(queue.enqueue(GameCommand(handle, 1, 'overflow'), table), isFalse);
    expect(queue.drain(1, table).map((c) => c.payload), ['first', 'second']);
    expect(queue.drain(3, table), isEmpty);
    expect(queue.enqueue(GameCommand(handle, 2, 'late'), table), isFalse);
    expect(() => queue.drain(2, table), throwsStateError);
    expect(() => GameCommand(handle, -1, 'invalid'), throwsRangeError);
  });
  test('generations remain safe with bounded retained identity history', () {
    final table = GameEntityTable(limits: GameLimits(maxEntities: 1));
    final old = table.spawn('a');
    table.despawn(old);
    for (var i = 0; i < 20; i++) {
      final handle = table.spawn('temporary-$i');
      table.despawn(handle);
    }
    final next = table.spawn('a');
    expect(table.isAlive(old), isFalse);
    expect(next.generation, greaterThan(old.generation));
  });
}
