import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'perception_test.dart' show Fixture;

void main() {
  test(
    'identical captures reuse exact tensors without another native query',
    () {
      final f = Fixture();
      try {
        f.entity('target', const Vec3(0, 0, -8));
        f.world.step();
        final captured = f.snapshot();
        final cache = SensorSampleCache();
        final first = f.makeAssembler();
        final second = f.makeAssembler();
        final frame = first.build(captured, f.actor, cache: cache);
        expect(first.registry.diagnostics.single.queriesUsed, greaterThan(0));
        final physicsRevision = f.world.revision;
        final reused = second.build(captured, f.actor, cache: cache);
        expect(reused.tensor.bytes, frame.tensor.bytes);
        expect(reused.visibleIds, frame.visibleIds);
        expect(
          identical(reused.readings.single, frame.readings.single),
          isTrue,
        );
        expect(second.registry.diagnostics.single.reused, isTrue);
        expect(second.registry.diagnostics.single.queriesUsed, 0);
        expect(f.world.revision, physicsRevision);
        expect(cache.hits, 1);
        final uncached = second.build(captured, f.actor);
        expect(uncached.tensor.bytes, frame.tensor.bytes);
        expect(uncached.sensorProfileHash, frame.sensorProfileHash);
        expect(
          uncached.readings.single.provenance,
          frame.readings.single.provenance,
        );
      } finally {
        f.world.close();
      }
    },
  );

  test(
    'world mutation and same-snapshot geometry unloading invalidate reuse',
    () {
      final f = Fixture();
      try {
        f.entity('target', const Vec3(0, 0, -8));
        final door = f.obstacle(const Vec3(5, 0, -4), const Vec3(1, 2, .2));
        f.world.step();
        final captured = f.snapshot();
        final cache = SensorSampleCache();
        final assembler = f.makeAssembler();
        expect(assembler.build(captured, f.actor, cache: cache).visibleIds, [
          'target',
        ]);
        door.teleport(PhysicsPose(position: const Vec3(0, 0, -4)));
        final blocked = assembler.build(captured, f.actor, cache: cache);
        expect(blocked.visibleIds, isEmpty);
        expect(assembler.registry.diagnostics.single.reused, isFalse);
        expect(
          blocked.tensor.bytes,
          assembler.build(captured, f.actor).tensor.bytes,
        );
        f.loaded = false;
        final unknown = assembler.build(captured, f.actor, cache: cache);
        expect(unknown.readings.single.reason, 'partial-catalog-coverage');
        expect(unknown.entityMask, [0, 0]);
        expect(assembler.registry.diagnostics.single.reused, isFalse);
        final reused = assembler.build(captured, f.actor, cache: cache);
        expect(reused.tensor.bytes, unknown.tensor.bytes);
        expect(assembler.registry.diagnostics.single.reused, isTrue);
        final beforeReload = f.world.revision;
        f.loaded = true;
        final reloaded = assembler.build(captured, f.actor, cache: cache);
        expect(reloaded.readings.single.reason, 'partial-catalog-coverage');
        expect(
          assembler.registry.diagnostics.single.queriesUsed,
          greaterThan(0),
        );
        expect(assembler.registry.diagnostics.single.reused, isFalse);
        expect(f.world.revision, greaterThan(beforeReload));
        f.world.close();
        expect(
          assembler
              .build(captured, f.actor, cache: cache)
              .readings
              .single
              .state,
          SensorState.unavailable,
        );
        expect(assembler.registry.diagnostics.single.reused, isFalse);
      } finally {
        f.world.close();
      }
    },
  );

  test(
    'material differences never borrow another visibility result',
    () {
      final f = Fixture();
      try {
        f.entity('target', const Vec3(0, 0, -8));
        f.obstacle(
          const Vec3(0, 0, -4),
          const Vec3(1, 2, .1),
          material: SensorMaterial.glass,
        );
        f.world.step();
        final cache = SensorSampleCache();
        final captured = f.snapshot();
        final blocked = f.makeAssembler();
        final pass = f.makeAssembler(
          materials: {SensorMaterial.glass: SensorMaterialRule.pass},
        );
        expect(
          blocked.build(captured, f.actor, cache: cache).readings.single.state,
          SensorState.unknown,
        );
        final visible = pass.build(captured, f.actor, cache: cache);
        expect(visible.visibleIds, ['target']);
        expect(pass.registry.diagnostics.single.reused, isFalse);
        expect(
          visible.tensor.bytes,
          pass.build(captured, f.actor).tensor.bytes,
        );
        final starved = f.makeAssembler(queryBudget: 0);
        final unknown = starved.build(captured, f.actor, cache: cache);
        expect(unknown.readings.single.reason, 'partial-catalog-coverage');
        expect(unknown.entityMask, [0, 0]);
        expect(starved.registry.diagnostics.single.reused, isFalse);
      } finally {
        f.world.close();
      }
    },
  );

  test('geometry-check retention overflow samples normally', () {
    final f = Fixture();
    try {
      f.entity('target', const Vec3(0, 0, -8));
      f.world.step();
      final captured = f.snapshot();
      final cache = SensorSampleCache(maxGeometryChecks: 0);
      final assembler = f.makeAssembler();
      final first = assembler.build(captured, f.actor, cache: cache);
      final second = assembler.build(captured, f.actor, cache: cache);
      expect(second.tensor.bytes, first.tensor.bytes);
      expect(cache.entries, 0);
      expect(cache.capacityMisses, 2);
      expect(assembler.registry.diagnostics.single.queriesUsed, greaterThan(0));
    } finally {
      f.world.close();
    }
  });
}
