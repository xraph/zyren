part of '../../zyren_game.dart';

enum GameCameraMode { firstPerson, thirdPerson, vehicle }

final class GameCameraDefinition {
  final GameCameraMode mode;
  final String? target;
  final double radius, eyeHeight, thirdPersonDistance, vehicleDistance;
  GameCameraDefinition({
    this.mode = GameCameraMode.thirdPerson,
    String? target,
    this.radius = .15,
    this.eyeHeight = .6,
    this.thirdPersonDistance = 4,
    this.vehicleDistance = 8,
  }) : target = target == null ? null : _id(target) {
    if (![
          radius,
          eyeHeight,
          thirdPersonDistance,
          vehicleDistance,
        ].every((v) => v.isFinite) ||
        radius <= 0 ||
        radius > 2 ||
        eyeHeight < 0 ||
        eyeHeight > 10 ||
        thirdPersonDistance <= radius ||
        thirdPersonDistance > 100 ||
        vehicleDistance <= radius ||
        vehicleDistance > 100) {
      throw ArgumentError('Invalid camera rig constraints.');
    }
  }
  Map<String, Object?> toJson() => {
    'mode': mode.name,
    if (target != null) 'target': target,
    'radius': radius,
    'eyeHeight': eyeHeight,
    'thirdPersonDistance': thirdPersonDistance,
    'vehicleDistance': vehicleDistance,
  };
  factory GameCameraDefinition.fromJson(Map<String, Object?> data) =>
      GameCameraDefinition(
        mode: GameCameraMode.values.byName(_string(data['mode'])),
        target: data['target'] == null ? null : _string(data['target']),
        radius: _vehicleDefinitionNumber(data['radius']),
        eyeHeight: _vehicleDefinitionNumber(data['eyeHeight']),
        thirdPersonDistance: _vehicleDefinitionNumber(
          data['thirdPersonDistance'],
        ),
        vehicleDistance: _vehicleDefinitionNumber(data['vehicleDistance']),
      );
}

/// Query bounds and the existing item/receipt rule share one authored schema.
final class GameInteractionDefinition {
  final String id, label;
  final String? target;
  final double reach;
  final int maxCandidates, maxTargets, receiptCapacity;
  final Map<String, int> requiredItems;
  final bool consumeItems;
  GameInteractionDefinition({
    this.id = 'interact',
    this.label = 'Interact',
    String? target,
    this.reach = 2,
    this.maxCandidates = 16,
    this.maxTargets = 128,
    Map<String, int> requiredItems = const {},
    this.consumeItems = false,
    this.receiptCapacity = 4096,
  }) : target = target == null ? null : _id(target),
       requiredItems = Map.unmodifiable(requiredItems) {
    _validateItems(requiredItems);
    _limit(receiptCapacity, 65536, 'interaction receipts');
    if (id.isEmpty ||
        id.length > 128 ||
        label.isEmpty ||
        label.length > 256 ||
        !reach.isFinite ||
        reach <= 0 ||
        reach > 100 ||
        maxCandidates < 1 ||
        maxCandidates > 128 ||
        maxTargets < 1 ||
        maxTargets > 1024) {
      throw ArgumentError('Invalid interaction definition.');
    }
  }
  GameInteraction instantiate(GameEntityHandle targetHandle) {
    if (target != null && targetHandle.id != target) {
      throw StateError('Interaction target differs from authored identity.');
    }
    return GameInteraction(
      id: id,
      target: targetHandle,
      requiredItems: requiredItems,
      consumeItems: consumeItems,
      receiptCapacity: receiptCapacity,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    if (target != null) 'target': target,
    'reach': reach,
    'maxCandidates': maxCandidates,
    'maxTargets': maxTargets,
    'requiredItems': requiredItems,
    'consumeItems': consumeItems,
    'receiptCapacity': receiptCapacity,
  };
  factory GameInteractionDefinition.fromJson(Map<String, Object?> data) =>
      GameInteractionDefinition(
        id: _string(data['id']),
        label: _string(data['label']),
        target: data['target'] == null ? null : _string(data['target']),
        reach: _vehicleDefinitionNumber(data['reach']),
        maxCandidates: _integer(data['maxCandidates']),
        maxTargets: _integer(data['maxTargets']),
        requiredItems: _itemMap(data['requiredItems']),
        consumeItems: data['consumeItems'] as bool,
        receiptCapacity: _integer(data['receiptCapacity']),
      );
}

/// Call once on a mutable registry, before capturing a project or editor snapshot.
void registerGameComponentCodecs(GameRegistry registry) {
  registry.registerComponent(
    _GameDefinitionCodec<GameCharacterDefinition>(
      'game.character',
      GameCharacterDefinition.fromJson,
    ),
  );
  registry.registerComponent(
    _GameDefinitionCodec<VehicleDefinition>(
      'game.vehicle',
      VehicleDefinition.fromJson,
    ),
  );
  registry.registerComponent(
    _GameDefinitionCodec<GameCameraDefinition>(
      'game.camera',
      GameCameraDefinition.fromJson,
      targetReference: true,
    ),
  );
  registry.registerComponent(
    _GameDefinitionCodec<GameInputMap>('game.input', GameInputMap.fromJson),
  );
  registry.registerComponent(
    _GameDefinitionCodec<GameInteractionDefinition>(
      'game.interaction',
      GameInteractionDefinition.fromJson,
      targetReference: true,
    ),
  );
  registerGameplayComponents(registry);
}

final class _GameDefinitionCodec<T extends Object>
    extends GameComponentCodec<T> {
  @override
  final String type;
  final T Function(Map<String, Object?>) _decode;
  final bool targetReference;
  _GameDefinitionCodec(this.type, this._decode, {this.targetReference = false});
  @override
  int get version => 1;
  @override
  void validate(Map<String, Object?> data) {
    _decode(data);
  }

  @override
  T factory(Map<String, Object?> data) => _decode(data);
  @override
  Iterable<GameLocalReference> localReferences(Map<String, Object?> data) =>
      targetReference && data['target'] != null
      ? [
          GameLocalReference(['target'], _string(data['target'])),
        ]
      : const [];
  @override
  Map<String, Object?> migrate(int fromVersion, Map<String, Object?> data) =>
      throw FormatException('Unsupported $type schema $fromVersion.');
}
