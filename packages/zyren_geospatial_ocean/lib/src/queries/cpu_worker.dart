import 'dart:async';
import 'dart:isolate';
import 'package:zyren/zyren.dart';
import '../surface/wave_chart.dart';
import '../waves/sea_state.dart';
import '../waves/spectrum.dart';
import 'canonical.dart';
import 'inversion.dart';

final class OceanWorkerException implements Exception {
  final OceanQueryFailure failure;
  const OceanWorkerException(this.failure);
  @override
  String toString() => 'Ocean worker: ${failure.name}.';
}

final class OceanWorkerDiagnostics {
  final int seededCharts, cacheHits, residentCharts, logicalWorkBytes;
  const OceanWorkerDiagnostics(
    this.seededCharts,
    this.cacheHits,
    this.residentCharts,
    this.logicalWorkBytes,
  );
}

/// A single persistent isolate with bounded admission and an LRU of fixed charts.
/// Returned snapshots belong to the caller and require separate retention budgets.
final class OceanCanonicalWorker {
  final OceanSeaState state;
  final int maxCharts, maxModesPerChart, maxPending, maxLogicalBytes;
  final Duration operationTimeout;
  final _receive = ReceivePort();
  final _ready = Completer<void>(), _done = Completer<void>();
  final _pending = <int, _Pending>{};
  Isolate? _isolate;
  late SendPort _send;
  bool _accepting = true, _exited = false;
  OceanQueryFailure? _terminalFailure;
  int _nextId = 0;
  OceanWorkerDiagnostics _diagnostics = const OceanWorkerDiagnostics(
    0,
    0,
    0,
    0,
  );
  OceanCanonicalWorker._(
    this.state,
    this.maxCharts,
    this.maxModesPerChart,
    this.maxPending,
    this.maxLogicalBytes,
    this.operationTimeout,
  );
  static Future<OceanCanonicalWorker> start(
    OceanSeaState state, {
    int maxCharts = 6,
    int maxModesPerChart = 262144,
    int maxPending = 2,
    int maxLogicalBytes = 256 * 1024 * 1024,
    Duration operationTimeout = const Duration(seconds: 30),
  }) async {
    if (maxCharts < 1 ||
        maxCharts > 6 ||
        maxPending < 1 ||
        maxPending > 8 ||
        maxLogicalBytes < 1 ||
        maxLogicalBytes > 1024 * 1024 * 1024 ||
        operationTimeout <= Duration.zero ||
        operationTimeout > const Duration(minutes: 2)) {
      throw ArgumentError('Invalid CPU ocean worker limits.');
    }
    final admission = OceanCanonicalField(
      state,
      maxModes: maxModesPerChart,
      maxLogicalBytes: maxLogicalBytes ~/ maxCharts,
    );
    final replacementBytes =
        96 *
        state.canonicalResolution *
        state.canonicalResolution *
        state.bands.length;
    if (admission.logicalWorkBytes * maxCharts + replacementBytes >
        maxLogicalBytes) {
      throw ArgumentError(
        'Canonical worker caches and replacement exceed their memory budget.',
      );
    }
    final worker = OceanCanonicalWorker._(
      state,
      maxCharts,
      maxModesPerChart,
      maxPending,
      maxLogicalBytes,
      operationTimeout,
    );
    worker._receive.listen(worker._message);
    try {
      worker._isolate = await Isolate.spawn(
        _workerMain,
        _Init(
          worker._receive.sendPort,
          state,
          maxCharts,
          maxModesPerChart,
          maxLogicalBytes,
        ),
        onError: worker._receive.sendPort,
        onExit: worker._receive.sendPort,
        debugName: 'ocean-canonical',
      );
      if (worker._terminalFailure != null) {
        worker._isolate?.kill(priority: Isolate.immediate);
      }
      await worker._ready.future.timeout(operationTimeout);
      return worker;
    } catch (_) {
      worker._accepting = false;
      worker._receive.close();
      worker._isolate?.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  int get pendingBatches => _pending.length;
  OceanWorkerDiagnostics get diagnostics => _diagnostics;
  Future<OceanCanonicalSnapshot> prepare(
    int chart,
    double seconds, {
    LoadCancellation? cancellation,
  }) async =>
      await _request(chart, seconds, null, 0, cancellation)
          as OceanCanonicalSnapshot;
  Future<List<OceanReferenceSample>> sample(
    int chart,
    double seconds,
    List<(double, double)> points, {
    required int maxModeEvaluations,
    LoadCancellation? cancellation,
  }) async => List.unmodifiable(
    await _request(chart, seconds, points, maxModeEvaluations, cancellation)
        as List<OceanReferenceSample>,
  );

  Future<Object> _request(
    int chart,
    double seconds,
    List<(double, double)>? points,
    int maxModeEvaluations,
    LoadCancellation? cancellation,
  ) async {
    if (!_accepting) throw const OceanWorkerException(OceanQueryFailure.closed);
    if (_pending.length >= maxPending) {
      throw const OceanWorkerException(OceanQueryFailure.busy);
    }
    if (chart < 0 ||
        chart >= 6 ||
        !seconds.isFinite ||
        seconds.abs() > 1e12 ||
        (points != null &&
            (points.isEmpty ||
                points.length > 4096 ||
                points.any(
                  (p) =>
                      !p.$1.isFinite ||
                      !p.$2.isFinite ||
                      p.$1.abs() > 1e12 ||
                      p.$2.abs() > 1e12,
                )))) {
      throw ArgumentError('Invalid bounded canonical worker request.');
    }
    if (points != null &&
        (maxModeEvaluations < 1 ||
            maxModeEvaluations > 134217728 ||
            points.length *
                    state.canonicalResolution *
                    state.canonicalResolution *
                    state.bands.length >
                maxModeEvaluations)) {
      throw const OceanWorkerException(OceanQueryFailure.workBudget);
    }
    cancellation?.throwIfCancelled();
    final id = ++_nextId, completer = Completer<Object>();
    final timer = Timer(
      operationTimeout,
      () => _terminate(OceanQueryFailure.workBudget),
    );
    _pending[id] = _Pending(completer, timer, cancellation);
    _send.send(
      _Job(
        id,
        chart,
        seconds,
        points == null ? null : List<(double, double)>.unmodifiable(points),
      ),
    );
    return completer.future;
  }

  void _message(Object? message) {
    if (message is SendPort) {
      _send = message;
      if (!_ready.isCompleted) _ready.complete();
    } else if (message is _Reply) {
      if (_terminalFailure != null) return;
      final pending = _pending.remove(message.id);
      if (pending == null) return;
      pending.timer.cancel();
      _diagnostics = message.diagnostics;
      if (pending.cancellation?.isCancelled ?? false) {
        pending.completer.completeError(LoadCancelled());
      } else if (message.failure != null) {
        pending.completer.completeError(OceanWorkerException(message.failure!));
      } else {
        pending.completer.complete(message.value!);
      }
    } else if (message == null) {
      _finish();
    } else {
      _terminate(OceanQueryFailure.failed);
    }
  }

  void _terminate(OceanQueryFailure failure) {
    if (_exited) return;
    _accepting = false;
    _terminalFailure = failure;
    _isolate?.kill(priority: Isolate.immediate);
    // Keep admission until the isolate's exit notification confirms termination.
  }

  void _finish() {
    if (_exited) return;
    _exited = true;
    _accepting = false;
    final failure = OceanWorkerException(
      _terminalFailure ?? OceanQueryFailure.closed,
    );
    if (!_ready.isCompleted) _ready.completeError(failure);
    for (final pending in _pending.values) {
      pending.timer.cancel();
      pending.completer.completeError(failure);
    }
    _pending.clear();
    _receive.close();
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> close() {
    if (_accepting) {
      _accepting = false;
      _send.send(const _Stop());
    }
    return _done.future;
  }
}

final class _Pending {
  final Completer<Object> completer;
  final Timer timer;
  final LoadCancellation? cancellation;
  _Pending(this.completer, this.timer, this.cancellation);
}

final class _Init {
  final SendPort reply;
  final OceanSeaState state;
  final int maxCharts, maxModes, maxBytes;
  _Init(this.reply, this.state, this.maxCharts, this.maxModes, this.maxBytes);
}

final class _Job {
  final int id, chart;
  final double seconds;
  final List<(double, double)>? points;
  _Job(this.id, this.chart, this.seconds, this.points);
}

final class _Reply {
  final int id;
  final Object? value;
  final OceanQueryFailure? failure;
  final OceanWorkerDiagnostics diagnostics;
  _Reply(this.id, this.value, this.failure, this.diagnostics);
}

final class _Stop {
  const _Stop();
}

final class _CachedChart {
  final OceanCanonicalField field;
  OceanCanonicalSnapshot? snapshot;
  _CachedChart(this.field);
}

void _workerMain(_Init init) async {
  final input = ReceivePort(), charts = <int, _CachedChart>{};
  final seeds = OceanWaveCharts(seed: init.state.seed);
  var seeded = 0, hits = 0;
  OceanWorkerDiagnostics diagnostics() => OceanWorkerDiagnostics(
    seeded,
    hits,
    charts.length,
    charts.values.fold(
      96 *
          init.state.canonicalResolution *
          init.state.canonicalResolution *
          init.state.bands.length,
      (sum, chart) => sum + chart.field.logicalWorkBytes,
    ),
  );
  init.reply.send(input.sendPort);
  await for (final message in input) {
    if (message is _Stop) {
      input.close();
      break;
    }
    if (message is! _Job) continue;
    try {
      var chart = charts[message.chart];
      final fresh = chart == null;
      if (chart == null) {
        if (charts.length == init.maxCharts) charts.remove(charts.keys.first);
        final source = init.state;
        chart = _CachedChart(
          OceanCanonicalField(
            OceanSeaState(
              seed: seeds.seedFor(message.chart),
              canonicalResolution: source.canonicalResolution,
              bands: source.bands,
              gravity: source.gravity,
              density: source.density,
              meanLevel: source.meanLevel,
              spectrum: source.spectrum,
            ),
            maxModes: init.maxModes,
            maxLogicalBytes: init.maxBytes ~/ init.maxCharts,
          ),
        );
      }
      if (chart.snapshot?.seconds == message.seconds) {
        hits++;
      } else {
        chart.snapshot = chart.field.at(message.seconds);
      }
      if (fresh) seeded++;
      charts.remove(message.chart);
      charts[message.chart] = chart;
      final points = message.points, snapshot = chart.snapshot!;
      final Object result = points == null
          ? snapshot
          : <OceanReferenceSample>[
              for (final p in points) snapshot.sample(p.$1, p.$2),
            ];
      init.reply.send(_Reply(message.id, result, null, diagnostics()));
    } catch (_) {
      init.reply.send(
        _Reply(
          message.id,
          null,
          OceanQueryFailure.unsupportedState,
          diagnostics(),
        ),
      );
    }
  }
}
