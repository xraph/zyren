import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';

List<WheelDefinition> wheels() => [
  for (final z in [-1.0, 1.0])
    for (final x in [-.7, .7])
      WheelDefinition(id: '$x:$z', mount: Vec3(x, 0, z), steering: z > 0),
];

void main() {
  test(
    'one registry constructs the same shared immutable runtime definitions',
    () {
      final registry = GameRegistry();
      registerGameComponentCodecs(registry);
      final character = GameCharacterDefinition();
      final vehicle = VehicleDefinition(wheels: wheels());
      expect(
        registry.construct(
          GameComponentRecord('game.character', 1, character.toJson()),
        ),
        isA<GameCharacterDefinition>(),
      );
      expect(
        registry.construct(
          GameComponentRecord('game.vehicle', 1, vehicle.toJson()),
        ),
        isA<VehicleDefinition>(),
      );
      expect(
        registry.construct(
          GameComponentRecord(
            'game.camera',
            1,
            GameCameraDefinition().toJson(),
          ),
        ),
        isA<GameCameraDefinition>(),
      );
      expect(
        registry.construct(
          GameComponentRecord(
            'game.interaction',
            1,
            GameInteractionDefinition().toJson(),
          ),
        ),
        isA<GameInteractionDefinition>(),
      );
      expect(() => registerGameComponentCodecs(registry), throwsStateError);
    },
  );
  test('wheel mount collisions reject extra tire forces at the same point', () {
    final original = wheels();
    expect(
      () => VehicleDefinition(
        wheels: [
          ...original,
          WheelDefinition(id: 'duplicate-left', mount: original[0].mount),
          WheelDefinition(id: 'duplicate-right', mount: original[1].mount),
        ],
      ),
      throwsArgumentError,
    );
    expect(
      VehicleDefinition(
        wheels: [
          ...original,
          WheelDefinition(id: 'middle-left', mount: const Vec3(-.7, 0, 0)),
          WheelDefinition(id: 'middle-right', mount: const Vec3(.7, 0, 0)),
        ],
      ).wheels,
      hasLength(6),
    );
  });
  test(
    'camera and interaction references remain declared and rules reuse item costs',
    () {
      final registry = GameRegistry();
      registerGameComponentCodecs(registry);
      final camera = GameComponentRecord(
        'game.camera',
        1,
        GameCameraDefinition(target: 'target').toJson(),
      );
      expect(registry.references(camera).single.path, ['target']);
      final interaction = GameInteractionDefinition(
        target: 'target',
        requiredItems: {'key': 1},
        consumeItems: true,
      );
      final record = GameComponentRecord(
        'game.interaction',
        1,
        interaction.toJson(),
      );
      expect(registry.references(record).single.targetId, 'target');
      final table = GameEntityTable();
      final actor = table.spawn('actor'), target = table.spawn('target');
      final inventory = Inventory(capacity: 2, items: {'key': 1});
      expect(
        interaction
            .instantiate(target)
            .tryApply(
              actor: actor,
              entities: table,
              inventory: inventory,
              receipt: 'one',
              inReach: true,
            ),
        isTrue,
      );
      expect(inventory.count('key'), 0);
      expect(() => interaction.instantiate(actor), throwsStateError);
    },
  );
}
