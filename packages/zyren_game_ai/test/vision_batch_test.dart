import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'perception_test.dart' show Fixture;

void main() {
  test(
    'vision batches keep scalar candidate quotas and visible-slot stopping',
    () {
      final f = Fixture();
      try {
        f.entity('a', const Vec3(-1, 0, -2));
        f.entity('b', const Vec3(1, 0, -2));
        f.entity('c', const Vec3(0, 0, -4));
        f.entity('d', const Vec3(2, 0, -6));
        f.entity('e-outside', const Vec3(0, 0, 2));
        f.obstacle(const Vec3(0, 0, -3), const Vec3(.4, 1, .2));
        for (final limit in [0, 1, 2, 3, 4, 6, 32]) {
          for (final slots in [1, 2, 3, 4]) {
            SensorProfile profile({bool sequential = false}) => SensorProfile(
              range: 10,
              maxEntities: slots,
              queryBudget: limit,
              materials: sequential
                  ? {SensorMaterial.smoke: SensorMaterialRule.pass}
                  : {},
            );
            final batch = VisionSensor(profile());
            final scalar = VisionSensor(profile(sequential: true));
            final a = batch.sample(f.snapshot(), f.actor);
            final b = scalar.sample(f.snapshot(), f.actor);
            expect(a.values, b.values, reason: '$limit queries / $slots slots');
            expect(a.validity, b.validity);
            expect(
              a.entities.map((e) => e.handle),
              b.entities.map((e) => e.handle),
            );
            expect(a.state, b.state);
            expect(a.reason, b.reason);
            expect(
              batch.lastDiagnostics!.queriesUsed,
              scalar.lastDiagnostics!.queriesUsed,
            );
            expect(batch.lastDiagnostics!.state, scalar.lastDiagnostics!.state);
            expect(
              batch.lastDiagnostics!.reason,
              scalar.lastDiagnostics!.reason,
            );
          }
        }
        final limited = VisionSensor(SensorProfile(range: 10, maxEntities: 2));
        expect(
          limited
              .sample(f.snapshot(), f.actor)
              .entities
              .map((e) => e.handle.id),
          ['a', 'b'],
        );
        expect(limited.lastDiagnostics!.queriesUsed, 2);
      } finally {
        f.world.close();
      }
    },
  );

  test('visible target identity resolves before its material policy', () {
    final f = Fixture();
    try {
      f.entity('target', const Vec3(0, 0, -2));
      final id = f.colliders.entries
          .singleWhere((e) => e.value.entity?.id == 'target')
          .key;
      f.colliders[id] = SensorCollider(
        SensorMaterial.unknown,
        entity: f.colliders[id]!.entity,
      );
      final sensor = VisionSensor(SensorProfile(range: 10));
      expect(
        sensor.sample(f.snapshot(), f.actor).entities.single.handle.id,
        'target',
      );
      f.colliders[id] = const SensorCollider(SensorMaterial.unknown);
      expect(sensor.sample(f.snapshot(), f.actor).entities, isEmpty);
    } finally {
      f.world.close();
    }
  });

  test('maximum visible catalog keeps native batches within 256 rays', () {
    final f = Fixture();
    try {
      for (var i = 0; i < 257; i++) {
        f.entity(
          'target-${i.toString().padLeft(3, '0')}',
          Vec3((i - 128).toDouble(), 0, -100),
        );
      }
      final sensor = VisionSensor(
        SensorProfile(
          range: 1000,
          halfAngleRadians: math.pi,
          maxEntities: 256,
          maxCandidates: 4096,
          queryBudget: 4096,
        ),
      );
      final reading = sensor.sample(f.snapshot(), f.actor);
      expect(reading.entities, hasLength(256));
      expect(reading.entities.first.handle.id, 'target-000');
      expect(reading.entities.last.handle.id, 'target-255');
      expect(sensor.lastDiagnostics!.queriesUsed, 256);
    } finally {
      f.world.close();
    }
  });
}
