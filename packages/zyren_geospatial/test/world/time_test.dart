import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

class Probe extends GeoSimulationSystem {
  @override
  final String id;
  @override
  final Set<String> dependencies;
  @override
  final GeoSimulationPhase phase;
  @override
  final bool supportsReplay;
  final FutureOr<void> Function(GeoInstant)? onStep;
  final List<int> ticks = [];
  Probe(
    this.id, {
    this.dependencies = const {},
    this.phase = GeoSimulationPhase.integrate,
    this.supportsReplay = true,
    this.onStep,
  });
  @override
  Future<void> step(GeoInstant instant) async {
    ticks.add(instant.tick);
    await onStep?.call(instant);
  }

  @override
  void restore(GeoInstant instant) {
    ticks.clear();
  }
}

void main() {
  test(
    'clock ownership stays reserved until asynchronous simulation work drains',
    () async {
      final entered = Completer<void>(), gate = Completer<void>();
      final clock = GeoSimulationClock();
      final clockDriver = clock.acquireDriver('application');
      final driver = GeoSimulation(
        systems: [
          Probe(
            'body',
            onStep: (_) async {
              entered.complete();
              await gate.future;
            },
          ),
        ],
      ).acquireDriver('application');
      final pending = driver.advance(
        clockDriver,
        const Duration(microseconds: 16667),
      );
      await entered.future;
      expect(clockDriver.step, throwsStateError);
      expect(clockDriver.beginAdvance, throwsStateError);
      clockDriver.dispose();
      expect(() => clock.acquireDriver('competing'), throwsStateError);
      gate.complete();
      expect(await pending, 1);
      final next = clock.acquireDriver('next');
      next.dispose();
      driver.dispose();
    },
  );

  test('separate hosts own independent default clocks and local frames', () {
    final first = GeospatialPlugin(), second = GeospatialPlugin();
    first.clock.step();
    expect(first.clock.tick, 1);
    expect(second.clock.tick, 0);
    expect(first.worldFrame, isNot(same(second.worldFrame)));
  });

  test(
    'driver ownership drains asynchronous steps and survives lease changes',
    () async {
      final entered = Completer<void>(), gate = Completer<void>();
      final probe = Probe(
        'pending',
        onStep: (_) async {
          if (!entered.isCompleted) entered.complete();
          await gate.future;
        },
      );
      final graph = GeoSimulation(systems: [probe]);
      final driver = graph.acquireDriver('first');
      final instant = GeoInstant(tick: 1, hz: 60, epoch: DateTime.utc(2026));
      final work = driver.step(instant);
      await entered.future;
      driver.dispose();
      expect(() => graph.acquireDriver('second'), throwsStateError);
      expect(
        () => GeoSimulation(systems: [probe]).acquireDriver('other'),
        throwsStateError,
      );
      gate.complete();
      await work;
      await driver.whenClosed;
      final next = graph.acquireDriver('second');
      await expectLater(next.step(instant), throwsStateError);
      await next.step(instant.withTick(2));
      expect(probe.ticks, [1, 2]);
      next.dispose();
    },
  );

  test('clock bounds large admissions without corrupting accounting', () {
    final clock = GeoSimulationClock(hz: 1000000);
    clock.setRate(numerator: 1000000, denominator: 1);
    expect(() => clock.advance(const Duration(days: 365)), throwsArgumentError);
    expect(clock.tick, 0);
    expect(clock.droppedTicks, 0);
  });

  test('a rejected timeline does not advance the clock or systems', () async {
    final clock = GeoSimulationClock();
    clock.step();
    final lease = clock.acquireDriver('application');
    final probe = Probe('body');
    final driver = GeoSimulation(systems: [probe]).acquireDriver('application');
    await expectLater(
      driver.advance(lease, const Duration(seconds: 1)),
      throwsStateError,
    );
    expect(clock.tick, 1);
    expect(probe.ticks, isEmpty);
    lease.dispose();
    driver.dispose();
  });

  test('pause does not turn wall time into a jump on resume', () {
    final clock = GeoSimulationClock(hz: 60);
    clock.paused = true;
    expect(clock.advance(const Duration(hours: 1)), 0);
    expect(clock.tick, 0);
    clock.paused = false;
    expect(clock.advance(const Duration(microseconds: 16667)), 1);
  });

  test(
    'integer admission bounds catchup and rational speed without time drift',
    () {
      final clock = GeoSimulationClock(hz: 60, maxCatchUpSteps: 8);
      for (var i = 0; i < 1000; i++) {
        clock.advance(const Duration(milliseconds: 1));
      }
      expect(clock.tick, 60);
      expect(clock.advance(const Duration(seconds: 1)), 8);
      expect(clock.droppedTicks, 52);
      clock.setRate(numerator: 1, denominator: 2);
      for (var i = 0; i < 1000; i++) {
        clock.advance(const Duration(milliseconds: 1));
      }
      expect(clock.tick, 98);
      expect(
        () => clock.advance(const Duration(microseconds: -1)),
        throwsArgumentError,
      );
      expect(
        () => GeoInstant(tick: 0, hz: 0, epoch: DateTime.utc(2026)),
        throwsArgumentError,
      );
    },
  );

  test('clock leases block competing drivers and direct steps', () {
    final clock = GeoSimulationClock();
    final owner = clock.acquireDriver('world');
    expect(() => clock.acquireDriver('other'), throwsStateError);
    expect(() => clock.step(), throwsStateError);
    expect(() => clock.advance(const Duration(seconds: 1)), throwsStateError);
    owner.step();
    expect(clock.tick, 1);
    owner.dispose();
    expect(() => owner.step(), throwsStateError);
    clock.step();
    expect(clock.tick, 2);
  });

  test(
    'external tick acceptance rejects old time and requires replay generation',
    () {
      final clock = GeoExternalClock();
      final first = GeoInstant(tick: 10, hz: 60, epoch: DateTime.utc(2026));
      expect(clock.accept(first), isTrue);
      expect(clock.accept(first), isFalse);
      expect(
        () => clock.accept(GeoInstant(tick: 9, hz: 60, epoch: first.epoch)),
        throwsStateError,
      );
      clock.beginReplay(
        GeoInstant(tick: 2, hz: 60, epoch: first.epoch, generation: 1),
      );
      expect(clock.instant.tick, 2);
      expect(clock.instant.generation, 1);
      expect(
        clock.accept(
          GeoInstant(tick: 3, hz: 60, epoch: first.epoch, generation: 1),
        ),
        isTrue,
      );
    },
  );

  test(
    'leased system graph orders phases and only steps each accepted tick once',
    () async {
      final calls = <String>[];
      final fields = Probe(
        'fields',
        phase: GeoSimulationPhase.sample,
        onStep: (_) => calls.add('fields'),
      );
      final body = Probe(
        'body',
        dependencies: {'fields'},
        onStep: (_) => calls.add('body'),
      );
      final graph = GeoSimulation(systems: [body, fields]);
      final driver = graph.acquireDriver('application');
      expect(() => graph.acquireDriver('other'), throwsStateError);
      final clock = GeoSimulationClock(hz: 10);
      final clockDriver = clock.acquireDriver('application');
      expect(
        await driver.advance(clockDriver, const Duration(milliseconds: 200)),
        2,
      );
      expect(calls, ['fields', 'body', 'fields', 'body']);
      await expectLater(driver.step(clock.instant), throwsStateError);
      expect(body.ticks, [1, 2]);
      await driver.beginReplay(
        GeoInstant(tick: 0, hz: 10, epoch: clock.instant.epoch, generation: 1),
      );
      await driver.step(
        GeoInstant(tick: 1, hz: 10, epoch: clock.instant.epoch, generation: 1),
      );
      expect(body.ticks, [1]);
      driver.dispose();
      clockDriver.dispose();
    },
  );

  test(
    'failed steps report partial progress and prevent an implicit retry',
    () async {
      final first = Probe('first');
      final failure = Probe(
        'failure',
        dependencies: {'first'},
        onStep: (_) => throw StateError('failed'),
      );
      final driver = GeoSimulation(
        systems: [failure, first],
      ).acquireDriver('owner');
      final instant = GeoInstant(tick: 1, hz: 60, epoch: DateTime.utc(2026));
      await expectLater(
        driver.step(instant),
        throwsA(
          isA<GeoSimulationFailure>().having(
            (e) => e.completedSystemIds,
            'completed',
            ['first'],
          ),
        ),
      );
      expect(driver.failure, isNotNull);
      await expectLater(driver.step(instant), throwsStateError);
      expect(first.ticks, [1]);
      driver.dispose();
    },
  );

  test(
    'invalid dependency graphs and unsupported replay fail before stepping',
    () async {
      expect(
        () => GeoSimulation(
          systems: [
            Probe('a', dependencies: {'missing'}),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => GeoSimulation(
          systems: [
            Probe('a', dependencies: {'b'}),
            Probe('b', dependencies: {'a'}),
          ],
        ),
        throwsArgumentError,
      );
      final system = Probe('stateful', supportsReplay: false);
      final driver = GeoSimulation(systems: [system]).acquireDriver('owner');
      await expectLater(
        driver.beginReplay(
          GeoInstant(tick: 0, hz: 60, epoch: DateTime.utc(2026), generation: 1),
        ),
        throwsUnsupportedError,
      );
      expect(system.ticks, isEmpty);
      driver.dispose();
    },
  );
}
