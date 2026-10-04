part of '../../zyren_game_ai.dart';

enum SensorMaterial { opaque, glass, foliage, smoke, unknown }

enum SensorMaterialRule { block, pass, unknown }

final class SensorProfile {
  final double range, halfAngleRadians;
  final Vec3 forward;
  final int maxEntities, maxCandidates, queryBudget, cadenceTicks;
  final int layerMask;
  final Map<SensorMaterial, SensorMaterialRule> materials;
  SensorProfile({
    this.range = 30,
    this.halfAngleRadians = math.pi / 3,
    Vec3 forward = const Vec3(0, 0, -1),
    this.maxEntities = 16,
    this.maxCandidates = 128,
    this.queryBudget = 128,
    this.cadenceTicks = 1,
    this.layerMask = 0xffffffff,
    Map<SensorMaterial, SensorMaterialRule> materials = const {},
  }) : forward = forward.normalized(),
       materials = Map.unmodifiable({
         SensorMaterial.opaque: SensorMaterialRule.block,
         SensorMaterial.glass: SensorMaterialRule.unknown,
         SensorMaterial.foliage: SensorMaterialRule.unknown,
         SensorMaterial.smoke: SensorMaterialRule.unknown,
         SensorMaterial.unknown: SensorMaterialRule.unknown,
         ...materials,
       }) {
    if (!range.isFinite ||
        range <= 0 ||
        range > 100000 ||
        !halfAngleRadians.isFinite ||
        halfAngleRadians < 0 ||
        halfAngleRadians > math.pi ||
        layerMask < 0 ||
        layerMask > 0xffffffff) {
      throw ArgumentError('Invalid sensor geometry.');
    }
    _bounded(maxEntities, 256, 'maxEntities');
    _bounded(maxCandidates, 4096, 'maxCandidates');
    _bounded(queryBudget, 4096, 'queryBudget', zero: true);
    _bounded(cadenceTicks, 3600, 'cadenceTicks');
    if (maxEntities > maxCandidates) {
      throw ArgumentError('Candidate bound is below slot bound.');
    }
  }
  double get cosHalfAngle => math.cos(halfAngleRadians);
  bool contains(Vec3 local) =>
      local.isFinite &&
      local.length <= range + 1e-9 &&
      (local.length <= 1e-9 ||
          local.normalized().dot(forward) >= cosHalfAngle - 1e-12);
  late final String hash = _hash({
    'range': range,
    'angle': halfAngleRadians,
    'forward': forward.storage,
    'maxEntities': maxEntities,
    'maxCandidates': maxCandidates,
    'queries': queryBudget,
    'cadence': cadenceTicks,
    'layers': layerMask,
    'materials': {
      for (final m in SensorMaterial.values) m.name: materials[m]!.name,
    },
  });
}
