import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';

GameSession rulesSession(GameGameplaySystem rules) => GameSession(
  project: CompiledGameProject(
    project: GameProject(
      id: 'g',
      startupLevel: 'l',
      levels: [
        GameLevel(id: 'l', scene: GameSceneIdentity('s', 'p'), entities: []),
      ],
      registry: GameRegistry(),
    ),
  ),
  seed: 1,
  systems: [rules],
);
void main() {
  test(
    'session applies each receipt once and cancels removed actor abilities',
    () async {
      final rules = GameGameplaySystem();
      final game = rulesSession(rules)..step();
      final actor = game.entities.spawn('actor');
      final receiver = game.entities.spawn('bag');
      final ability = Ability(id: 'dash', cooldownTicks: 3, durationTicks: 5);
      final actorRules = GameActorRules(
        inventory: Inventory(capacity: 3, items: {'key': 2}),
        abilities: {'dash': ability},
      );
      final bag = Inventory(capacity: 3);
      rules.bind(actor, actorRules);
      rules.bind(receiver, GameActorRules(inventory: bag));
      final transfer = GameTransferItem(
        'receipt1',
        sequence: 1,
        item: 'key',
        count: 1,
        to: receiver,
      );
      for (var i = 0; i < 2; i++) {
        game.commands.enqueue(
          GameCommand(actor, game.tick + 1, transfer),
          game.entities,
        );
      }
      game.step();
      expect(bag.count('key'), 1);
      expect(actorRules.inventory.count('key'), 1);
      expect(
        game.events.drain().where((e) => e.payload is GameGameplayResult),
        hasLength(1),
      );
      game.commands.enqueue(
        GameCommand(actor, game.tick + 1, transfer),
        game.entities,
      );
      game.step();
      expect(
        bag.count('key'),
        1,
        reason: 'a retried receipt on another tick must not spend twice',
      );
      expect(
        game.events.drain().where((e) => e.payload is GameGameplayResult),
        isEmpty,
      );
      game.commands.enqueue(
        GameCommand(
          actor,
          game.tick + 1,
          GameUseAbility('ability1', 'dash', sequence: 2),
        ),
        game.entities,
      );
      game.step();
      expect(ability.active, isNotNull);
      final records = actorRules.snapshot();
      final receipt = records.singleWhere((r) => r.type == 'game.receipts');
      expect(GameReceiptCursor.fromJson(receipt.data).sequence, 2);
      final saved = records.singleWhere((r) => r.type == 'game.abilities');
      expect(
        GameAbilityCollection.fromJson(
          saved.data,
        ).abilities['dash']!.nextAllowedTick,
        ability.nextAllowedTick,
      );
      game.entities.despawn(actor);
      game.step();
      expect(ability.active, isNull);
      await game.close();
    },
  );
  test('failed transfer leaves both inventories unchanged', () {
    final source = Inventory(capacity: 8, items: {'key': 2});
    final full = Inventory(capacity: 1, items: {'coin': 1});
    expect(source.transfer(item: 'key', count: 1, to: full), isFalse);
    expect(source.count('key'), 2);
    expect(full.count('key'), 0);
    expect(source.transfer(item: 'key', count: 0, to: full), isFalse);
    final bag = Inventory(capacity: 4);
    expect(source.transfer(item: 'key', count: 1, to: bag), isTrue);
    expect(source.count('key'), 1);
    expect(bag.count('key'), 1);
    expect(Inventory.fromJson(bag.toJson()).toJson(), bag.toJson());
  });
  test(
    'ability validates all costs and retains cooldown on cancellation and restore',
    () {
      final actor = GameEntityHandle('player', 1);
      final bag = Inventory(capacity: 8, items: {'mana': 3});
      final ability = Ability(
        id: 'dash',
        cooldownTicks: 30,
        durationTicks: 4,
        costs: {'mana': 2},
      );
      expect(
        ability.tryActivate(actor: actor, inventory: bag, tick: 10),
        isNotNull,
      );
      expect(
        ability.tryActivate(actor: actor, inventory: bag, tick: 10),
        isNull,
      );
      expect(bag.count('mana'), 1);
      expect(ability.cancel(actor), isTrue);
      final restored = Ability.fromJson(ability.toJson());
      expect(
        restored.tryActivate(actor: actor, inventory: bag, tick: 39),
        isNull,
      );
      bag.add('mana', 2);
      expect(
        restored.tryActivate(actor: actor, inventory: bag, tick: 40),
        isNotNull,
      );
      expect(restored.advance(44), isNotNull);
      expect(restored.advance(44), isNull);
      expect(() => restored.advance(43), throwsStateError);
    },
  );
  test('trigger and objective do not award duplicate credit', () {
    final actor = GameEntityHandle('player', 1);
    final trigger = GameTrigger(id: 'exit', oncePerActor: true);
    expect(trigger.enter(actor), isTrue);
    expect(trigger.enter(actor), isFalse);
    trigger.exit(actor);
    expect(trigger.enter(actor), isFalse);
    final objectives = ObjectiveTracker({'findKey': 1, 'exit': 1});
    expect(objectives.credit('findKey', receipt: 'pickup:1'), isTrue);
    expect(objectives.credit('findKey', receipt: 'pickup:1'), isFalse);
    expect(objectives.completed, isFalse);
    expect(objectives.credit('exit', receipt: 'exit:1'), isTrue);
    expect(objectives.completed, isTrue);
    final restored = ObjectiveTracker.fromJson(objectives.toJson());
    expect(restored.completed, isTrue);
    expect(restored.credit('exit', receipt: 'exit:1'), isFalse);
  });
  test('key gate objective loop consumes only an accepted interaction', () {
    final entities = GameEntityTable();
    final actor = entities.spawn('player');
    final gate = entities.spawn('gate');
    final inventory = Inventory(capacity: 4, items: {'key': 1});
    final objectives = ObjectiveTracker({'openGate': 1});
    final interaction = GameInteraction(
      id: 'unlock',
      target: gate,
      requiredItems: {'key': 1},
      consumeItems: true,
    );
    expect(
      interaction.tryApply(
        actor: actor,
        entities: entities,
        inventory: inventory,
        receipt: 'cmd1',
        inReach: false,
      ),
      isFalse,
    );
    expect(inventory.count('key'), 1);
    expect(
      interaction.tryApply(
        actor: actor,
        entities: entities,
        inventory: inventory,
        receipt: 'cmd1',
        inReach: true,
      ),
      isTrue,
    );
    objectives.credit('openGate', receipt: 'cmd1');
    expect(inventory.count('key'), 0);
    expect(objectives.completed, isTrue);
    expect(
      interaction.tryApply(
        actor: actor,
        entities: entities,
        inventory: inventory,
        receipt: 'cmd1',
        inReach: true,
      ),
      isFalse,
    );
    entities.despawn(gate);
    inventory.add('key', 1);
    expect(
      interaction.tryApply(
        actor: actor,
        entities: entities,
        inventory: inventory,
        receipt: 'cmd2',
        inReach: true,
      ),
      isFalse,
    );
  });
  test('component codecs validate and restore gameplay snapshots', () {
    final registry = GameRegistry();
    registerGameplayComponents(registry);
    final bag = Inventory(capacity: 3, items: {'key': 1});
    final record = GameComponentRecord('game.inventory', 1, bag.toJson());
    expect((registry.construct(record) as Inventory).count('key'), 1);
    expect(
      () => registry.construct(
        GameComponentRecord('game.inventory', 1, {
          'capacity': 1,
          'items': {'key': 2},
        }),
      ),
      throwsFormatException,
    );
  });
}
