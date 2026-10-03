part of '../../zyren_game.dart';

enum GameColliderShape { box, capsule, sphere }

enum GameBodyMotion { fixed, dynamic, kinematic }

/// Names the imported clips and root that drive an existing character motor.
final class GameCharacterRigDefinition {
  final int rootMotionNode;
  final String movingClip;
  final String? idleClip;
  final Vec3 visualOffset;
  GameCharacterRigDefinition({
    required this.rootMotionNode,
    required this.movingClip,
    this.idleClip,
    this.visualOffset = const Vec3(0, -.8, 0),
  }) {
    bool validName(String value) =>
        value.trim().isNotEmpty && value.length <= 256;
    if (rootMotionNode < 0 ||
        rootMotionNode > 1000000 ||
        !validName(movingClip) ||
        (idleClip != null && !validName(idleClip!)) ||
        !visualOffset.isFinite ||
        visualOffset.storage.any((v) => v.abs() > 1000)) {
      throw ArgumentError('Invalid character rig mapping.');
    }
  }
  Map<String, Object?> toJson() => {
    'rootMotionNode': rootMotionNode,
    'movingClip': movingClip,
    if (idleClip != null) 'idleClip': idleClip,
    'visualOffset': visualOffset.storage,
  };
  factory GameCharacterRigDefinition.fromJson(Map<String, Object?> data) {
    final offset = _list(data['visualOffset']);
    if (offset.length != 3) {
      throw const FormatException('Expected three visual offset values.');
    }
    return GameCharacterRigDefinition(
      rootMotionNode: data['rootMotionNode'] as int,
      movingClip: data['movingClip'] as String,
      idleClip: data['idleClip'] as String?,
      visualOffset: Vec3(
        (offset[0] as num).toDouble(),
        (offset[1] as num).toDouble(),
        (offset[2] as num).toDouble(),
      ),
    );
  }
}

/// Metres, kilograms and unitless contact coefficients consumed by native hosts.
final class GameColliderDefinition {
  final GameColliderShape shape;
  final GameBodyMotion motion;
  final Vec3 halfExtents;
  final double radius, halfHeight, mass, friction, restitution;
  final bool sensor;
  GameColliderDefinition({
    this.shape = GameColliderShape.box,
    this.motion = GameBodyMotion.fixed,
    this.halfExtents = const Vec3(.5, .5, .5),
    this.radius = .3,
    this.halfHeight = .6,
    this.mass = 80,
    this.friction = .7,
    this.restitution = 0,
    this.sensor = false,
  }) {
    if (!halfExtents.isFinite ||
        halfExtents.storage.any((v) => v <= 0 || v > 10000) ||
        ![
          radius,
          halfHeight,
          mass,
          friction,
          restitution,
        ].every((v) => v.isFinite) ||
        radius <= 0 ||
        radius > 1000 ||
        halfHeight < 0 ||
        halfHeight > 1000 ||
        mass <= 0 ||
        mass > 1e7 ||
        friction < 0 ||
        friction > 10 ||
        restitution < 0 ||
        restitution > 1) {
      throw ArgumentError('Invalid collider dimensions or contact properties.');
    }
  }
  Map<String, Object?> toJson() => {
    'shape': shape.name,
    'motion': motion.name,
    'halfExtents': halfExtents.storage,
    'radius': radius,
    'halfHeight': halfHeight,
    'mass': mass,
    'friction': friction,
    'restitution': restitution,
    'sensor': sensor,
  };
  factory GameColliderDefinition.fromJson(Map<String, Object?> data) {
    final extents = _list(data['halfExtents']);
    if (extents.length != 3) {
      throw const FormatException('Expected three box half extents.');
    }
    return GameColliderDefinition(
      shape: GameColliderShape.values.byName(_string(data['shape'])),
      motion: GameBodyMotion.values.byName(_string(data['motion'])),
      halfExtents: Vec3(
        (extents[0] as num).toDouble(),
        (extents[1] as num).toDouble(),
        (extents[2] as num).toDouble(),
      ),
      radius: (data['radius'] as num).toDouble(),
      halfHeight: (data['halfHeight'] as num).toDouble(),
      mass: (data['mass'] as num).toDouble(),
      friction: (data['friction'] as num).toDouble(),
      restitution: (data['restitution'] as num).toDouble(),
      sensor: data['sensor'] as bool,
    );
  }
}

/// Definitions remain data; hosts use their existing level manager and physics.
void registerGameLevelCodecs(GameRegistry registry) {
  registry.registerComponent(
    _GameDefinitionCodec<GameCharacterRigDefinition>(
      'game.character-rig',
      GameCharacterRigDefinition.fromJson,
    ),
  );
  registry.registerComponent(
    _GameDefinitionCodec<GameColliderDefinition>(
      'game.collider',
      GameColliderDefinition.fromJson,
    ),
  );
  for (final type in [
    'game.spawn',
    'game.checkpoint',
    'game.level-link',
    'game.level-settings',
  ]) {
    registry.registerComponent(_GameLevelComponentCodec(type));
  }
}

final class _GameLevelComponentCodec
    extends GameComponentCodec<Map<String, Object?>> {
  @override
  final String type;
  _GameLevelComponentCodec(this.type);
  @override
  int get version => 1;
  @override
  void validate(Map<String, Object?> data) {
    switch (type) {
      case 'game.spawn':
        _id(_string(data['group']));
      case 'game.checkpoint':
        _id(_string(data['spawn']));
        final radius = data['radius'];
        if (radius is! num ||
            !radius.isFinite ||
            radius <= 0 ||
            radius > 1000) {
          throw ArgumentError('Checkpoint radius must be in (0,1000].');
        }
      case 'game.level-link':
        _id(_string(data['level']));
        _id(_string(data['spawnGroup']));
      case 'game.level-settings':
        GameBuildProfile.fromJson(_map(data['profile']));
        if (data['navigation'] != null) {
          final navigation = _map(data['navigation']);
          if (!RegExp(
                r'^[a-f0-9]{64}$',
              ).hasMatch(_string(navigation['documentGeometryHash'])) ||
              navigation['settings'] is! Map ||
              navigation['sources'] is! List) {
            throw const FormatException('Invalid navigation bake receipt.');
          }
        }
    }
  }

  @override
  Map<String, Object?> factory(Map<String, Object?> data) {
    validate(data);
    return _json(data);
  }

  @override
  Iterable<GameLocalReference> localReferences(Map<String, Object?> data) =>
      type == 'game.checkpoint'
      ? [
          GameLocalReference(['spawn'], _string(data['spawn'])),
        ]
      : const [];
  @override
  Map<String, Object?> migrate(int fromVersion, Map<String, Object?> data) =>
      throw FormatException('Unsupported $type version $fromVersion.');
}
