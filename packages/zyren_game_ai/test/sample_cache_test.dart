import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'registry_test.dart' show CustomSensor;

final actor = GameEntityHandle('actor', 1);
SensorSnapshot snapshot({int Function()? revision}) => SensorSnapshot(
  episodeId: 'ep',
  tick: 1,
  worldRevision: 1,
  entities: [SensorEntity(handle: actor, pose: PhysicsPose(), grounded: true)],
  colliders: {},
  currentRevision: revision ?? () => 1,
  geometryLoaded: (_, _) => true,
);
SensorReading sample(
  GameSensor sensor,
  SensorSnapshot captured,
  SensorSampleCache cache,
) => (SensorRegistry()..register(sensor)).sample(
  sensor,
  captured,
  actor,
  cache: cache,
);

void main() {
  test('equivalent built-in configurations reuse only the same capture', () {
    final cache = SensorSampleCache();
    final captured = snapshot();
    final first = sample(BodySensor(), captured, cache);
    final sensor = BodySensor();
    final registry = SensorRegistry()..register(sensor);
    expect(
      identical(first, registry.sample(sensor, captured, actor, cache: cache)),
      isTrue,
    );
    expect(registry.diagnostics.single.reused, isTrue);
    expect(registry.diagnostics.single.queriesUsed, 0);
    expect(cache.hits, 1);
    expect(cache.misses, 1);
    expect(cache.entries, 1);
    sample(BodySensor(), snapshot(), cache);
    expect(cache.hits, 1);
    expect(cache.entries, 1);
  });

  test('body scaling and every vision profile pin remain distinct', () {
    final cache = SensorSampleCache();
    final captured = snapshot();
    final first = sample(BodySensor(maxSpeed: 10), captured, cache);
    final second = sample(BodySensor(maxSpeed: 20), captured, cache);
    expect(identical(first, second), isFalse);
    for (final profile in [
      SensorProfile(range: 10),
      SensorProfile(range: 20),
      SensorProfile(range: 10, halfAngleRadians: .5),
      SensorProfile(range: 10, layerMask: 2),
      SensorProfile(range: 10, queryBudget: 0),
      SensorProfile(
        range: 10,
        materials: {SensorMaterial.glass: SensorMaterialRule.pass},
      ),
    ]) {
      sample(VisionSensor(profile), captured, cache);
    }
    expect(cache.hits, 0);
    expect(cache.entries, 8);
    sample(VisionSensor(SensorProfile(range: 10)), captured, cache);
    expect(cache.hits, 1);
  });

  test('custom sensors execute and schema drift guards remain live', () {
    var calls = 0;
    final custom = CustomSensor('custom', mutate: () => calls++);
    final registry = SensorRegistry()..register(custom);
    final cache = SensorSampleCache();
    final captured = snapshot();
    registry.sample(custom, captured, actor, cache: cache);
    registry.sample(custom, captured, actor, cache: cache);
    expect(calls, 2);
    expect(cache.entries, 0);
    custom.units = 'metres';
    expect(
      () => registry.sample(custom, captured, actor, cache: cache),
      throwsStateError,
    );
    late CustomSensor during;
    during = CustomSensor('during', mutate: () => during.units = 'metres');
    final live = SensorRegistry()..register(during);
    expect(
      () => live.sample(during, captured, actor, cache: cache),
      throwsStateError,
    );
  });

  test('stale captures clear retained readings without inventing validity', () {
    var revision = 1;
    final captured = snapshot(revision: () => revision);
    final cache = SensorSampleCache();
    sample(BodySensor(), captured, cache);
    revision++;
    final reading = sample(BodySensor(), captured, cache);
    expect(reading.state, SensorState.unknown);
    expect(reading.validity, everyElement(0));
    expect(cache.hits, 0);
    expect(cache.entries, 0);
  });

  test('actor identities and retained value caps cannot share a row', () {
    final other = GameEntityHandle('other', 1);
    final captured = SensorSnapshot(
      episodeId: 'ep',
      tick: 1,
      worldRevision: 1,
      entities: [
        SensorEntity(handle: actor, pose: PhysicsPose(), grounded: true),
        SensorEntity(handle: other, pose: PhysicsPose(), grounded: false),
      ],
      colliders: {},
      currentRevision: () => 1,
      geometryLoaded: (_, _) => true,
    );
    final sensor = BodySensor();
    final registry = SensorRegistry()..register(sensor);
    final cache = SensorSampleCache(maxValues: 4);
    final first = registry.sample(sensor, captured, actor, cache: cache);
    final second = registry.sample(sensor, captured, other, cache: cache);
    expect(first.values.last, 1);
    expect(second.values.last, 0);
    expect(cache.entries, 1);
    expect(cache.capacityMisses, 1);
    expect(cache.hits, 0);
  });

  test('capacity overflow samples freshly and never expands retention', () {
    final cache = SensorSampleCache(maxEntries: 1);
    final captured = snapshot();
    sample(BodySensor(maxSpeed: 10), captured, cache);
    final first = sample(BodySensor(maxSpeed: 20), captured, cache);
    final second = sample(BodySensor(maxSpeed: 20), captured, cache);
    expect(identical(first, second), isFalse);
    expect(cache.entries, 1);
    expect(cache.capacityMisses, 2);
    expect(() => SensorSampleCache(maxEntries: 0), throwsArgumentError);
    cache.clear();
    expect(cache.entries, 0);
  });
}
