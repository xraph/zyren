import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/delayed_query_backend.dart';
import 'sample_test.dart' show queryFrame, queryTime, querySea;

final class TestCoverage implements GeoFieldSource<bool> {
  @override
  String get id => 'test-coast';
  @override
  String revision = 'one';
  bool allowed = true;
  bool landWest = false;
  int calls = 0;
  Future<void> Function(int)? onSample;
  @override
  String get units => 'boolean';
  @override
  GeoHeightDatum? get datum => null;
  @override
  Future<GeoSample<bool>> sample(Geodetic coordinate, GeoInstant time) async {
    await onSample?.call(++calls);
    return GeoSample(
      availability: allowed
          ? GeoSampleAvailability.available
          : GeoSampleAvailability.unavailable,
      value: allowed ? !(landWest && coordinate.longitude < 0) : null,
      sourceRevision: revision,
      frameId: 'body-fixed',
      frameRevision: 0,
      units: units,
      time: time,
      age: Duration.zero,
    );
  }
}

void main() {
  for (final scenario in [
    'reset',
    'rebase',
    'source',
    'removed',
    'stale',
    'cancel',
    'close',
  ]) {
    test(
      'delayed GPU readback fences $scenario and retains admission until drain',
      () async {
        final backend = DelayedQueryBackend(),
            scope = GpuScope.fromBackend(backend),
            frame = queryFrame(),
            coverage = TestCoverage();
        var now = queryTime();
        final state = OceanSeaState(
          seed: 42,
          canonicalResolution: 8,
          bands: [
            OceanWaveBand(
              patchMetres: 64,
              minWaveNumber: 0,
              maxWaveNumber: .5,
              windSpeed: 0,
              windHeadingRadians: 0,
              amplitude: .0002,
            ),
          ],
        );
        final sampler = await OceanSamplerGpu.create(
          state: state,
          frame: frame,
          now: () => now,
          coverage: coverage,
          scope: scope,
        );
        final cancel = LoadCancellationSource(),
            q = [OceanQuery(const Vec3(6378137, 0, 0), now)];
        try {
          final pending = sampler.sampleBatch(
            q,
            OceanQueryPolicy(),
            cancellation: cancel,
          );
          await backend.device.readStarted.future.timeout(
            const Duration(seconds: 5),
          );
          final busy = await sampler.sampleBatch(q, OceanQueryPolicy());
          expect(busy.single.failure, OceanQueryFailure.busy);
          Future<void>? closing;
          var closed = false;
          final expected = switch (scenario) {
            'reset' => OceanQueryFailure.timelineChanged,
            'rebase' => OceanQueryFailure.frameChanged,
            'source' => OceanQueryFailure.sourceChanged,
            'removed' => OceanQueryFailure.sourceUnavailable,
            'stale' => OceanQueryFailure.stale,
            'cancel' => OceanQueryFailure.cancelled,
            _ => OceanQueryFailure.closed,
          };
          switch (scenario) {
            case 'reset':
              now = GeoInstant(
                tick: now.tick,
                hz: now.hz,
                epoch: now.epoch,
                generation: 1,
              );
            case 'rebase':
              frame.rebase(Geodetic(.1, .2));
            case 'source':
              coverage.revision = 'two';
            case 'removed':
              coverage.allowed = false;
            case 'stale':
              now = now.withTick(now.tick + 1);
            case 'cancel':
              cancel.cancel();
            case 'close':
              closing = sampler.close().then((_) {
                closed = true;
              });
          }
          await Future<void>.delayed(Duration.zero);
          expect(closed, isFalse);
          expect(backend.device.allocations, isNotEmpty);
          backend.device.releaseRead.complete();
          final result = (await pending).single;
          expect(result.failure, expected);
          expect(result.value, isNull);
          expect(result.accuracy, isNull);
          await closing;
        } finally {
          if (!backend.device.releaseRead.isCompleted) {
            backend.device.releaseRead.complete();
          }
          await sampler.close();
          await scope.close();
          await frame.dispose();
          expect(backend.device.allocations, isEmpty);
          expect(backend.device.shaders, isEmpty);
          expect(backend.device.graphs, isEmpty);
        }
      },
    );
  }
  test(
    'partial coverage retains order, checks access again and bounds mixed times',
    () async {
      final frame = queryFrame(),
          time = queryTime(),
          coverage = TestCoverage()..landWest = true;
      final sampler = await OceanSamplerCpu.create(
        state: querySea(),
        frame: frame,
        now: () => time,
        coverage: coverage,
      );
      final queries = [
        for (final lon in [-.1, .1, .2])
          OceanQuery(Ellipsoid.wgs84.toEcef(Geodetic(lon, 0)), time),
      ];
      try {
        final samples = await sampler.sampleBatch(queries, OceanQueryPolicy());
        expect(samples.map((s) => s.failure), [
          OceanQueryFailure.outsideCoverage,
          null,
          null,
        ]);
        expect(samples.map((s) => s.query), queries);
        final mixed = [
          queries[1],
          OceanQuery(queries[1].positionEcef, time.withTick(time.tick - 1)),
        ];
        final rejected = await sampler.sampleBatch(
          mixed,
          OceanQueryPolicy(maxDistinctTimes: 1),
        );
        expect(
          rejected.every((s) => s.failure == OceanQueryFailure.workBudget),
          isTrue,
        );
        final accepted = await sampler.sampleBatch(
          mixed,
          OceanQueryPolicy(maxAge: const Duration(milliseconds: 17)),
        );
        expect(accepted.every((s) => s.available), isTrue);
        expect(accepted.last.age, const Duration(microseconds: 16667));
        coverage.calls = 0;
        coverage.onSample = (call) async {
          if (call == 2) coverage.allowed = false;
        };
        final denied = await sampler.sampleBatch([
          queries[1],
        ], OceanQueryPolicy());
        expect(denied.single.failure, OceanQueryFailure.sourceUnavailable);
      } finally {
        await sampler.close();
        await frame.dispose();
      }
    },
  );
  test('huge clock differences cannot overflow into a fresh sample', () async {
    final frame = queryFrame(), time = queryTime();
    final sampler = await OceanSamplerCpu.create(
      state: querySea(),
      frame: frame,
      now: () => time.withTick(9007199254740991),
      coverage: const OceanAllWaterCoverage(),
    );
    try {
      final result = await sampler.sampleBatch([
        OceanQuery(const Vec3(6378137, 0, 0), time),
      ], OceanQueryPolicy(maxAge: const Duration(days: 1)));
      expect(result.single.failure, OceanQueryFailure.stale);
      expect(sampler.diagnostics.modeEvaluations, 0);
    } finally {
      await sampler.close();
      await frame.dispose();
    }
  });
}
