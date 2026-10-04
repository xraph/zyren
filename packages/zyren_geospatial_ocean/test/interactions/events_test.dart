import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

final initial = GeoInstant(tick: 0, hz: 60, epoch: DateTime.utc(2026));
OceanInteraction event(
  String source,
  int sequence,
  int tick, {
  int generation = 0,
}) => OceanInteraction(
  id: OceanInteractionId(source, sequence),
  time: GeoInstant(
    tick: tick,
    hz: 60,
    epoch: initial.epoch,
    generation: generation,
  ),
  ecefPosition: const Vec3(6378137, 0, 0),
  relativeVelocity: const Vec3(0, 2, 0),
  radiusMetres: 1,
  energy: 1,
);
void main() {
  test(
    'events are ordered by tick, source and sequence with bounded deduplication',
    () {
      final queue = OceanInteractionQueue(initialTime: initial);
      expect(
        queue.enqueue(event('b', 0, 1)),
        OceanInteractionAdmission.accepted,
      );
      expect(
        queue.enqueue(event('a', 0, 1)),
        OceanInteractionAdmission.accepted,
      );
      expect(
        queue.enqueue(event('a', 1, 2)),
        OceanInteractionAdmission.accepted,
      );
      expect(
        queue.enqueue(event('a', 1, 2)),
        OceanInteractionAdmission.duplicate,
      );
      expect(queue.takeTick(initial.withTick(1)).map((e) => e.id.source), [
        'a',
        'b',
      ]);
      expect(
        queue.enqueue(event('a', 0, 3)),
        OceanInteractionAdmission.duplicate,
      );
      expect(queue.takeTick(initial.withTick(2)).single.id.sequence, 1);
      expect(queue.pendingCount, 0);
      expect(queue.sourceCount, 2);
      expect(queue.enqueue(event('c', 0, 2)), OceanInteractionAdmission.late);
      expect(() => queue.takeTick(initial.withTick(4)), throwsStateError);
    },
  );
  test(
    'source, future, per-tick and total queue limits reject before admission',
    () {
      final queue = OceanInteractionQueue(
        initialTime: initial,
        maxPending: 2,
        maxSources: 2,
        maxPerTick: 1,
        maxFutureTicks: 3,
      );
      expect(
        queue.enqueue(event('a', 0, 1)),
        OceanInteractionAdmission.accepted,
      );
      expect(
        queue.enqueue(event('b', 0, 1)),
        OceanInteractionAdmission.tickBudget,
      );
      expect(queue.sourceCount, 1);
      expect(
        queue.enqueue(event('b', 0, 4)),
        OceanInteractionAdmission.futureLimit,
      );
      expect(
        queue.enqueue(event('a', 1, 3)),
        OceanInteractionAdmission.accepted,
      );
      expect(
        queue.enqueue(event('b', 0, 2)),
        OceanInteractionAdmission.queueBudget,
      );
      queue.takeTick(initial.withTick(1));
      expect(
        queue.enqueue(event('a', 2, 2)),
        OceanInteractionAdmission.outOfOrder,
      );
      expect(
        queue.enqueue(event('b', 0, 2)),
        OceanInteractionAdmission.accepted,
      );
      queue.takeTick(initial.withTick(2));
      expect(
        queue.enqueue(event('c', 0, 3)),
        OceanInteractionAdmission.sourceBudget,
      );
    },
  );
  test(
    'new replay generations clear retained identities and reject old events',
    () {
      final queue = OceanInteractionQueue(initialTime: initial);
      queue.enqueue(event('boat', 5, 1));
      queue.takeTick(initial.withTick(1));
      queue.reset(1);
      expect(queue.sourceCount, 0);
      expect(queue.pendingCount, 0);
      expect(
        queue.enqueue(event('boat', 6, 1)),
        OceanInteractionAdmission.wrongTimeline,
      );
      expect(
        queue.enqueue(event('boat', 0, 1, generation: 1)),
        OceanInteractionAdmission.accepted,
      );
      final replay = GeoInstant(
        tick: 1,
        hz: 60,
        epoch: initial.epoch,
        generation: 1,
      );
      expect(queue.takeTick(replay).single.id.sequence, 0);
      expect(() => queue.reset(1), throwsArgumentError);
      final decoded = OceanInteraction.fromJson(event('boat', 0, 1).toJson());
      expect(decoded.ecefPosition, event('boat', 0, 1).ecefPosition);
      expect(decoded.atGeneration(3).time.generation, 3);
    },
  );
  test(
    'CFL admission includes boundary damping and rejects excessive work',
    () {
      final settings = OceanInteractionSettings(
        resolution: 64,
        extentMetres: 32,
        waveSpeed: 10,
      );
      final count = settings.substepsFor(30);
      final dt = 1 / 30 / count,
          ratio = settings.waveSpeed * dt / settings.cellMetres;
      expect(
        4 / 3 * ratio * ratio +
            (settings.damping + settings.boundaryDamping) * dt / 2,
        lessThanOrEqualTo(settings.courantLimit),
      );
      expect(
        () => OceanInteractionSettings(
          resolution: 64,
          extentMetres: 4,
          waveSpeed: 100,
          maxSubsteps: 1,
        ).substepsFor(30),
        throwsArgumentError,
      );
      expect(
        () => OceanInteractionSettings(resolution: 63, extentMetres: 32),
        throwsArgumentError,
      );
      expect(
        () => OceanInteractionSettings(
          resolution: 64,
          extentMetres: 32,
          courantLimit: 1.1,
        ),
        throwsArgumentError,
      );
    },
  );
}
