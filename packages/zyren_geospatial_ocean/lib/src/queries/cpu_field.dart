import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import '../waves/sea_state.dart';
import '../waves/spectrum.dart';
import 'canonical.dart';
import 'cpu_worker.dart';
import 'gpu_query.dart';
import 'inversion.dart';

/// Internal owned bridge. Mode packets copied to the host have a separate budget.
final class OceanQueryFields {
  final OceanSeaState state;
  final OceanCanonicalWorker worker;
  final OceanCanonicalGpu? gpu;
  final int hostLogicalBytes;
  final _packets = <int, OceanCanonicalSnapshot>{};
  final _envelopes = <int, OceanCanonicalEnvelope>{};
  double? _seconds;
  int modeEvaluations = 0, fieldBatches = 0, dispatches = 0, maxWork = 0;
  OceanQueryFields(this.state, this.worker, this.gpu, this.hostLogicalBytes);
  int get modes =>
      state.canonicalResolution *
      state.canonicalResolution *
      state.bands.length;
  void begin(int maxModeEvaluations) {
    modeEvaluations = fieldBatches = dispatches = 0;
    maxWork = maxModeEvaluations;
  }

  void _spend(int amount) {
    if (amount > maxWork - modeEvaluations) {
      throw const OceanWorkerException(OceanQueryFailure.workBudget);
    }
    modeEvaluations += amount;
  }

  void _time(double seconds) {
    if (_seconds == seconds) return;
    _seconds = seconds;
    _packets.clear();
    _envelopes.clear();
  }

  Future<List<OceanCanonicalEnvelope>> envelopes(
    double seconds,
    LoadCancellation? cancellation,
  ) async {
    _time(seconds);
    // Count preparation even when the worker serves a cache hit.
    _spend(6 * modes);
    for (var id = 0; id < 6; id++) {
      _envelopes[id] = await worker.envelope(
        id,
        seconds,
        cancellation: cancellation,
      );
    }
    return [for (var id = 0; id < 6; id++) _envelopes[id]!];
  }

  Future<({List<OceanReferenceSample> values, List<OceanFieldError> errors})>
  sample(
    int chart,
    double seconds,
    List<(double, double)> points,
    LoadCancellation? cancellation,
  ) async {
    _time(seconds);
    _spend(modes * (points.length + 1));
    fieldBatches++;
    final native = gpu;
    if (native != null) {
      var snapshot = _packets[chart];
      if (snapshot == null) {
        snapshot = await worker.prepare(
          chart,
          seconds,
          cancellation: cancellation,
        );
        _packets[chart] = snapshot;
      }
      final batch = await native.sample(
        snapshot,
        points,
        cancellation: cancellation,
      );
      dispatches += batch.dispatches;
      return (values: batch.values, errors: batch.errors);
    }
    final values = await worker.sample(
      chart,
      seconds,
      points,
      maxModeEvaluations: modes * points.length,
      cancellation: cancellation,
    );
    return (
      values: values,
      errors: [for (final p in points) _cpuError(_envelopes[chart]!, p)],
    );
  }

  OceanFieldError _cpuError(OceanCanonicalEnvelope e, (double, double) point) {
    // Float64 numeric model: correctly rounded basic arithmetic and <=4 ulp trig.
    // Include conservative uncompensated summation and world-coordinate reduction.
    // This is relative to the seeded Float64 packet, not the continuous sea model.
    const epsilon = 2.220446049250313e-16;
    var phase = 0.0;
    for (final band in state.bands) {
      phase = math.max(
        phase,
        64 *
            epsilon *
            math.pi *
            state.canonicalResolution *
            (1 + (point.$1.abs() + point.$2.abs()) / band.patchMetres),
      );
    }
    final gamma = modes * epsilon / (1 - modes * epsilon);
    final factor = 2 * phase + 64 * epsilon + 4 * gamma;
    return OceanFieldError(
      factor * e.height + epsilon * state.meanLevel.abs(),
      factor * e.displacement,
      factor * e.slope,
      factor * e.displacementGradient,
      factor * e.velocity,
    );
  }

  Future<void> close() async {
    _packets.clear();
    _envelopes.clear();
    try {
      await worker.close();
    } finally {
      await gpu?.close();
    }
  }
}
