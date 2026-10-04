import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'persistent CPU worker reuses canonical charts and keeps fixed seed identity',
    () async {
      final state = fixtureSea(),
          worker = await OceanCanonicalWorker.start(
            state,
            maxCharts: 2,
            maxModesPerChart: 64,
          );
      try {
        final first = await worker.prepare(0, 2.5),
            second = await worker.prepare(0, 2.5);
        expect(first.modes, orderedEquals(second.modes));
        expect(worker.diagnostics.seededCharts, 1);
        expect(worker.diagnostics.cacheHits, 1);
        final values = await worker.sample(0, 2.5, [
          (12.3, 5.0),
          (-3.0, 9.7),
        ], maxModeEvaluations: 128);
        expect(values[0].height, first.sample(12.3, 5).height);
        expect(values[1].height, first.sample(-3, 9.7).height);
      } finally {
        await worker.close();
      }
    },
  );
  test(
    'bounded admission, cancellation and close drain accepted CPU work',
    () async {
      final worker = await OceanCanonicalWorker.start(
        fixtureSea(),
        maxPending: 1,
        maxModesPerChart: 64,
      );
      final cancellation = LoadCancellationSource();
      final accepted = worker.sample(
        0,
        1,
        [(0.0, 0.0)],
        maxModeEvaluations: 64,
        cancellation: cancellation,
      );
      await expectLater(
        worker.prepare(1, 1),
        throwsA(isA<OceanWorkerException>()),
      );
      cancellation.cancel();
      final closed = worker.close();
      await expectLater(accepted, throwsA(isA<LoadCancelled>()));
      await closed;
      await expectLater(
        worker.prepare(0, 1),
        throwsA(isA<OceanWorkerException>()),
      );
      expect(worker.pendingBatches, 0);
    },
  );
  test(
    'chart eviction preserves deterministic state and counts replacement admission',
    () async {
      final state = fixtureSea();
      await expectLater(
        OceanCanonicalWorker.start(
          state,
          maxCharts: 1,
          maxModesPerChart: 64,
          maxLogicalBytes: 64 * 152,
        ),
        throwsArgumentError,
      );
      final worker = await OceanCanonicalWorker.start(
        state,
        maxCharts: 1,
        maxModesPerChart: 64,
      );
      try {
        final original = await worker.prepare(0, 3);
        await worker.prepare(1, 3);
        final restored = await worker.prepare(0, 3);
        expect(restored.modes, orderedEquals(original.modes));
        expect(worker.diagnostics.seededCharts, 3);
        expect(worker.diagnostics.residentCharts, 1);
        expect(worker.diagnostics.logicalWorkBytes, 64 * (152 + 96));
        await expectLater(
          worker.sample(0, 3, [(0.0, 0.0), (1.0, 1.0)], maxModeEvaluations: 64),
          throwsA(
            isA<OceanWorkerException>().having(
              (e) => e.failure,
              'failure',
              OceanQueryFailure.workBudget,
            ),
          ),
        );
      } finally {
        await worker.close();
      }
    },
  );
  test(
    'deadline termination releases admission only after the worker exits',
    () async {
      final source = fixtureSea();
      final worker = await OceanCanonicalWorker.start(
        OceanSeaState(
          seed: source.seed,
          canonicalResolution: 8,
          bands: source.bands,
          spectrum: const _SlowSpectrum(),
        ),
        maxModesPerChart: 64,
        operationTimeout: const Duration(milliseconds: 500),
      );
      await expectLater(
        worker.prepare(0, 0),
        throwsA(
          isA<OceanWorkerException>().having(
            (e) => e.failure,
            'failure',
            OceanQueryFailure.workBudget,
          ),
        ),
      );
      expect(worker.pendingBatches, 0);
      await worker.close();
    },
  );
}

final class _SlowSpectrum implements OceanSpectrumModel {
  const _SlowSpectrum();
  @override
  String get id => 'test-slow';
  @override
  int get version => 1;
  @override
  double energy(
    double kx,
    double kz,
    OceanWaveBand band, {
    double gravity = 9.81,
  }) {
    final watch = Stopwatch()..start();
    while (watch.elapsedMilliseconds < 2000) {}
    return const PhillipsSpectrum().energy(kx, kz, band, gravity: gravity);
  }
}
