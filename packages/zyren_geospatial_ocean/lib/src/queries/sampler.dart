import 'dart:async';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../surface/wave_chart.dart';
import '../waves/sea_state.dart';
import '../waves/spectrum.dart';
import 'accuracy.dart';
import 'cpu_field.dart';
import 'cpu_worker.dart';
import 'gpu_query.dart';
import 'inversion.dart';
import 'policy.dart';
import 'query.dart';
import 'world_surface.dart';

final class OceanSamplerLimits {
  final int maxSamples,
      maxModesPerChart,
      maxWorkerLogicalBytes,
      maxHostLogicalBytes,
      maxGpuLogicalBytes;
  final Duration operationTimeout;
  OceanSamplerLimits({
    this.maxSamples = 256,
    this.maxModesPerChart = 262144,
    this.maxWorkerLogicalBytes = 256 * 1024 * 1024,
    this.maxHostLogicalBytes = 256 * 1024 * 1024,
    this.maxGpuLogicalBytes = 128 * 1024 * 1024,
    this.operationTimeout = const Duration(seconds: 30),
  }) {
    if (maxSamples < 1 ||
        maxSamples > 4096 ||
        maxModesPerChart < 1 ||
        maxModesPerChart > 2097152 ||
        [
          maxWorkerLogicalBytes,
          maxHostLogicalBytes,
          maxGpuLogicalBytes,
        ].any((v) => v < 1 || v > 1 << 30) ||
        operationTimeout <= Duration.zero ||
        operationTimeout > const Duration(minutes: 2)) {
      throw ArgumentError('Invalid physical sampler limits.');
    }
  }
}

/// A sampler owns its immutable physical state and its evaluation resources.
/// Await batches. Close invalidates delivery, then drains accepted work.
sealed class OceanSampler {
  final OceanSeaState state;
  final GeoWorldFrame frame;
  final GeoInstant Function() now;
  final GeoFieldSource<bool> coverage;
  final OceanSamplerLimits limits;
  final OceanQueryFields _fields;
  late final OceanWaveCharts _charts = OceanWaveCharts(
    seed: state.seed,
    ellipsoid: frame.reference.ellipsoid,
  );
  bool _closed = false;
  Completer<void>? _pending;
  Future<void>? _closing;
  OceanSampler._(
    this.state,
    this.frame,
    this.now,
    this.coverage,
    this.limits,
    this._fields,
  );
  OceanQueryDiagnostics get diagnostics => OceanQueryDiagnostics(
    modeEvaluations: _fields.modeEvaluations,
    fieldBatches: _fields.fieldBatches,
    gpuDispatches: _fields.dispatches,
    workerLogicalBytes: _fields.worker.diagnostics.logicalWorkBytes,
    hostLogicalBytes: _fields.hostLogicalBytes,
    gpuLogicalBytes: _fields.gpu?.logicalPayloadBytes ?? 0,
  );

  Future<List<OceanSample>> sampleBatch(
    List<OceanQuery> queries,
    OceanQueryPolicy policy, {
    LoadCancellation? cancellation,
  }) async {
    if (queries.length > policy.maxSamples ||
        queries.length > limits.maxSamples) {
      throw ArgumentError('Query batch exceeds its sample limit.');
    }
    final input = List<OceanQuery>.unmodifiable(queries);
    if (input.isEmpty) return const [];
    final revision = frame.revision, source = coverage.revision;
    OceanSample failed(OceanQuery q, OceanQueryFailure f) =>
        _failure(q, f, revision, source);
    if (_closed) {
      return [for (final q in input) failed(q, OceanQueryFailure.closed)];
    }
    if (_pending != null) {
      return [for (final q in input) failed(q, OceanQueryFailure.busy)];
    }
    final groups = <GeoInstant, List<int>>{};
    for (var i = 0; i < input.length; i++) {
      (groups[input[i].time] ??= []).add(i);
    }
    if (groups.length > policy.maxDistinctTimes) {
      return [for (final q in input) failed(q, OceanQueryFailure.workBudget)];
    }
    final done = Completer<void>();
    _pending = done;
    _fields.begin(policy.maxModeEvaluations);
    final results = List<OceanSample?>.filled(input.length, null);
    try {
      for (final group in groups.entries) {
        final points = <int, _QueryPoint>{};
        for (final i in group.value) {
          try {
            _check(input[i], policy, revision, source, cancellation);
            final foot = oceanEllipsoidFootpoint(
              input[i].positionEcef,
              _charts.ellipsoid,
            );
            final point = _charts.atSurface(foot.position);
            await _covered(point.normal, input[i].time, source);
            _check(input[i], policy, revision, source, cancellation);
            points[i] = _QueryPoint(input[i], point);
          } catch (e) {
            results[i] = failed(input[i], _reason(e));
          }
        }
        if (points.isEmpty) continue;
        try {
          final envelopes = await _fields.envelopes(
            group.key.seconds,
            cancellation,
          );
          final bounds = OceanSurfaceBounds(
            ellipsoid: _charts.ellipsoid,
            meanLevel: state.meanLevel,
            charts: envelopes,
          );
          if (!bounds.admissible) {
            throw const OceanWorkerException(OceanQueryFailure.accuracy);
          }
          final batcher = _WorldBatcher(
            _fields,
            _charts,
            group.key.seconds,
            cancellation,
          );
          await Future.wait([
            for (final entry in points.entries)
              () async {
                final i = entry.key, point = entry.value;
                try {
                  _check(point.query, policy, revision, source, cancellation);
                  results[i] = await _solve(
                    point,
                    bounds,
                    batcher,
                    policy,
                    revision,
                    source,
                    cancellation,
                  );
                } catch (e) {
                  results[i] = failed(point.query, _reason(e));
                }
              }(),
          ]);
        } catch (e) {
          for (final i in points.keys) {
            results[i] = failed(input[i], _reason(e));
          }
        }
      }
      // Recheck source access after every group's physical work has drained.
      await Future.wait([
        for (var i = 0; i < input.length; i++)
          if (results[i]!.available)
            () async {
              try {
                _check(input[i], policy, revision, source, cancellation);
                final material = _charts.atSurface(
                  results[i]!.value!.materialEcef,
                );
                final origin = oceanEllipsoidFootpoint(
                  input[i].positionEcef,
                  _charts.ellipsoid,
                );
                await _covered(material.normal, input[i].time, source);
                await _covered(origin.normal, input[i].time, source);
              } catch (e) {
                results[i] = failed(input[i], _reason(e));
              }
            }(),
      ]);
      // Earlier groups may have aged or changed while later groups were evaluated.
      return List.unmodifiable([
        for (var i = 0; i < input.length; i++)
          () {
            try {
              final age = _check(
                input[i],
                policy,
                revision,
                source,
                cancellation,
              );
              final r = results[i]!;
              if (!r.available) return r;
              return OceanSample(
                query: r.query,
                failure: null,
                value: r.value,
                accuracy: r.accuracy,
                seaStateRevision: r.seaStateRevision,
                coverageRevision: r.coverageRevision,
                frameId: r.frameId,
                frameRevision: r.frameRevision,
                evaluatedTime: r.evaluatedTime,
                age: age,
                residual: r.residual,
              );
            } catch (e) {
              return failed(input[i], _reason(e));
            }
          }(),
      ]);
    } finally {
      _pending = null;
      done.complete();
    }
  }

  Future<OceanSample> _solve(
    _QueryPoint query,
    OceanSurfaceBounds bounds,
    _WorldBatcher batcher,
    OceanQueryPolicy policy,
    int revision,
    String source,
    LoadCancellation? cancellation,
  ) async {
    _Evaluation? last;
    final inverse = await invertOceanHorizontal(
      targetX: 0,
      targetY: 0,
      initialX: 0,
      initialY: 0,
      maxIterations: policy.maxIterations,
      tolerance: math.max(
        1e-10,
        math.min(1e-7, policy.maxHeightErrorMetres * 1e-4),
      ),
      maxStep: bounds.radius,
      maxDistance: bounds.radius,
      minimumSingularValue: 1 - bounds.horizontalContraction,
      cancellation: cancellation,
      evaluate: (x, y) async {
        _check(query.query, policy, revision, source, cancellation);
        final evaluation = await batcher.evaluate(query, x, y);
        _check(query.query, policy, revision, source, cancellation);
        last = evaluation;
        return evaluation.horizontal;
      },
    );
    if (inverse.failure != null) throw OceanWorkerException(inverse.failure!);
    final evaluated = last!;
    final accuracy = bounds.assess(
      residual: inverse.residual,
      materialDistance: math.sqrt(
        inverse.x! * inverse.x! + inverse.y! * inverse.y!,
      ),
      eastDerivative: evaluated.east,
      northDerivative: evaluated.north,
      fieldErrors: evaluated.errors,
    );
    if (accuracy == null ||
        accuracy.heightErrorMetres > policy.maxHeightErrorMetres ||
        accuracy.normalErrorRadians > policy.maxNormalErrorRadians ||
        accuracy.velocityErrorMetresPerSecond >
            policy.maxVelocityErrorMetresPerSecond) {
      throw const OceanWorkerException(OceanQueryFailure.accuracy);
    }
    final age = _check(query.query, policy, revision, source, cancellation);
    final surface = evaluated.surface;
    return OceanSample(
      query: query.query,
      failure: null,
      value: OceanSurfaceValue(
        positionEcef: surface.position,
        materialEcef: evaluated.material.position,
        normalEcef: surface.normal,
        velocityEcef: surface.velocity,
        positionLocal: frame.toLocal(surface.position),
        normalLocal: frame.vectorToLocal(surface.normal),
        velocityLocal: frame.vectorToLocal(surface.velocity),
        height: (surface.position - query.origin.position).dot(
          query.origin.normal,
        ),
      ),
      accuracy: accuracy,
      seaStateRevision: state.revision,
      coverageRevision: source,
      frameId: frame.id,
      frameRevision: revision,
      evaluatedTime: query.query.time,
      age: age,
      residual: inverse.residual,
    );
  }

  Future<void> _covered(Vec3 normal, GeoInstant time, String source) async {
    final result = await coverage.sample(
      Geodetic(
        math.atan2(normal.y, normal.x),
        math.asin(normal.z.clamp(-1, 1)),
      ),
      time,
    );
    if (coverage.revision != source ||
        (result.sourceRevision != null && result.sourceRevision != source)) {
      throw const OceanWorkerException(OceanQueryFailure.sourceChanged);
    }
    if (result.availability == GeoSampleAvailability.outsideCoverage ||
        (result.availability == GeoSampleAvailability.available &&
            result.value == false)) {
      throw const OceanWorkerException(OceanQueryFailure.outsideCoverage);
    }
    if (result.availability != GeoSampleAvailability.available ||
        result.value != true ||
        result.time != time) {
      throw const OceanWorkerException(OceanQueryFailure.sourceUnavailable);
    }
  }

  Duration _check(
    OceanQuery query,
    OceanQueryPolicy policy,
    int revision,
    String source,
    LoadCancellation? cancellation,
  ) {
    if (_closed) throw const OceanWorkerException(OceanQueryFailure.closed);
    cancellation?.throwIfCancelled();
    if (frame.revision != revision) {
      throw const OceanWorkerException(OceanQueryFailure.frameChanged);
    }
    if (coverage.revision != source) {
      throw const OceanWorkerException(OceanQueryFailure.sourceChanged);
    }
    final current = now();
    if (!query.time.sameTimeline(current)) {
      throw const OceanWorkerException(OceanQueryFailure.timelineChanged);
    }
    final elapsed =
            (BigInt.from(current.tick) - BigInt.from(query.time.tick)) *
            BigInt.from(1000000),
        rate = BigInt.from(current.hz);
    if (elapsed.isNegative ||
        elapsed > BigInt.from(policy.maxAge.inMicroseconds) * rate) {
      throw const OceanWorkerException(OceanQueryFailure.stale);
    }
    if (query.time.seconds > 1e12) {
      throw const OceanWorkerException(OceanQueryFailure.unsupportedState);
    }
    return Duration(
      microseconds: ((elapsed + rate - BigInt.one) ~/ rate).toInt(),
    );
  }

  OceanSample _failure(
    OceanQuery query,
    OceanQueryFailure reason,
    int revision,
    String source,
  ) => OceanSample(
    query: query,
    failure: reason,
    value: null,
    accuracy: null,
    seaStateRevision: state.revision,
    coverageRevision: source,
    frameId: frame.id,
    frameRevision: revision,
    evaluatedTime: null,
    age: null,
    residual: null,
  );
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await _pending?.future;
    await _fields.close();
  }
}

final class OceanSamplerCpu extends OceanSampler {
  OceanSamplerCpu._(
    super.state,
    super.frame,
    super.now,
    super.coverage,
    super.limits,
    super.fields,
  ) : super._();
  static Future<OceanSamplerCpu> create({
    required OceanSeaState state,
    required GeoWorldFrame frame,
    required GeoInstant Function() now,
    required GeoFieldSource<bool> coverage,
    OceanSamplerLimits? limits,
  }) async {
    final admitted = limits ?? OceanSamplerLimits();
    final fields = await _createFields(state, frame, coverage, admitted, null);
    return OceanSamplerCpu._(state, frame, now, coverage, admitted, fields);
  }
}

final class OceanSamplerGpu extends OceanSampler {
  OceanSamplerGpu._(
    super.state,
    super.frame,
    super.now,
    super.coverage,
    super.limits,
    super.fields,
  ) : super._();
  static Future<OceanSamplerGpu> create({
    required OceanSeaState state,
    required GeoWorldFrame frame,
    required GeoInstant Function() now,
    required GeoFieldSource<bool> coverage,
    required GpuScope scope,
    OceanSamplerLimits? limits,
  }) async {
    final admitted = limits ?? OceanSamplerLimits();
    final fields = await _createFields(state, frame, coverage, admitted, scope);
    return OceanSamplerGpu._(state, frame, now, coverage, admitted, fields);
  }
}

Future<OceanQueryFields> _createFields(
  OceanSeaState state,
  GeoWorldFrame frame,
  GeoFieldSource<bool> coverage,
  OceanSamplerLimits limits,
  GpuScope? scope,
) async {
  OceanWaveCharts(seed: state.seed, ellipsoid: frame.reference.ellipsoid);
  if (coverage.id.trim().isEmpty || coverage.revision.trim().isEmpty) {
    throw ArgumentError('Coverage needs explicit identity and revision.');
  }
  final modes =
      state.canonicalResolution *
      state.canonicalResolution *
      state.bands.length;
  // Host reserves six retained packets, one transfer, Float32 upload scratch,
  // plus bounded coordinate, sample and geometry payload. Object overhead excluded.
  final host =
      limits.maxSamples * 4096 +
      4096 +
      (scope == null ? 0 : modes * (7 * 96 + 48));
  if (host > limits.maxHostLogicalBytes) {
    throw ArgumentError('Host query payload exceeds its allowance.');
  }
  final worker = await OceanCanonicalWorker.start(
    state,
    maxCharts: 6,
    maxModesPerChart: limits.maxModesPerChart,
    maxPending: 1,
    maxLogicalBytes: limits.maxWorkerLogicalBytes,
    operationTimeout: limits.operationTimeout,
  );
  try {
    final gpu = scope == null
        ? null
        : await OceanCanonicalGpu.create(
            scope,
            maxSamples: limits.maxSamples,
            maxModes: limits.maxModesPerChart,
            maxLogicalBytes: limits.maxGpuLogicalBytes,
          );
    return OceanQueryFields(state, worker, gpu, host);
  } catch (_) {
    await worker.close();
    rethrow;
  }
}

OceanQueryFailure _reason(Object e) => switch (e) {
  OceanWorkerException(:final failure) => failure,
  LoadCancelled() => OceanQueryFailure.cancelled,
  ResourceException() => OceanQueryFailure.allocation,
  ArgumentError() => OceanQueryFailure.unsupportedState,
  _ => OceanQueryFailure.failed,
};

final class _QueryPoint {
  final OceanQuery query;
  final OceanChartPoint origin;
  _QueryPoint(this.query, this.origin);
}

final class _Evaluation {
  final OceanChartPoint material;
  final OceanWorldSurface surface;
  final OceanHorizontalField horizontal;
  final Vec3 east, north;
  final List<OceanFieldError> errors;
  _Evaluation(
    this.material,
    this.surface,
    this.horizontal,
    this.east,
    this.north,
    this.errors,
  );
}

final class _Waiting {
  final _QueryPoint query;
  final OceanChartPoint material;
  final Vec3 east, north;
  final result = Completer<_Evaluation>();
  _Waiting(this.query, this.material, this.east, this.north);
}

/// Coalesces Newton iterations across points without dispatching one batch per probe.
final class _WorldBatcher {
  final OceanQueryFields fields;
  final OceanWaveCharts charts;
  final double seconds;
  final LoadCancellation? cancellation;
  final _queue = <_Waiting>[];
  bool _running = false;
  _WorldBatcher(this.fields, this.charts, this.seconds, this.cancellation);
  Future<_Evaluation> evaluate(_QueryPoint query, double x, double y) {
    final o = query.origin,
        p = o.position + o.east * x + o.north * y,
        inverse = charts.ellipsoid.reciprocalRadiiSquared,
        bp = Vec3(inverse.x * p.x, inverse.y * p.y, inverse.z * p.z),
        s = 1 / math.sqrt(p.dot(bp)),
        material = charts.atSurface(p * s);
    Vec3 derivative(Vec3 direction) =>
        direction * s - p * (s * s * s * bp.dot(direction));
    final waiting = _Waiting(
      query,
      material,
      derivative(o.east),
      derivative(o.north),
    );
    _queue.add(waiting);
    if (!_running) {
      _running = true;
      scheduleMicrotask(_flush);
    }
    return waiting.result.future;
  }

  Future<void> _flush() async {
    final pending = List<_Waiting>.of(_queue);
    _queue.clear();
    try {
      final groups = <int, List<(_Waiting, OceanChartCoordinate)>>{};
      for (final p in pending) {
        for (final c in p.material.coordinates) {
          (groups[c.id] ??= []).add((p, c));
        }
      }
      final values = <_Waiting, Map<int, OceanReferenceSample>>{},
          errors = <_Waiting, List<OceanFieldError>>{};
      for (final group in groups.entries) {
        final batch = await fields.sample(group.key, seconds, [
          for (final entry in group.value) (entry.$2.u, entry.$2.v),
        ], cancellation);
        for (var i = 0; i < group.value.length; i++) {
          final p = group.value[i].$1;
          (values[p] ??= {})[group.key] = batch.values[i];
          (errors[p] ??= []).add(batch.errors[i]);
        }
      }
      for (final p in pending) {
        final surface = blendOceanSurface(p.material, (c) => values[p]![c.id]!);
        if (surface.orientation <= 0) {
          throw const OceanWorkerException(OceanQueryFailure.folded);
        }
        Vec3 derivative(Vec3 d) =>
            surface.eastDerivative * d.dot(p.material.east) +
            surface.northDerivative * d.dot(p.material.north);
        final east = derivative(p.east),
            north = derivative(p.north),
            origin = p.query.origin,
            delta = surface.position - origin.position;
        p.result.complete(
          _Evaluation(
            p.material,
            surface,
            OceanHorizontalField(
              delta.dot(origin.east),
              delta.dot(origin.north),
              east.dot(origin.east),
              north.dot(origin.east),
              east.dot(origin.north),
              north.dot(origin.north),
            ),
            east,
            north,
            errors[p]!,
          ),
        );
      }
    } catch (e, stack) {
      for (final p in pending) {
        if (!p.result.isCompleted) p.result.completeError(e, stack);
      }
    } finally {
      _running = false;
      if (_queue.isNotEmpty) {
        _running = true;
        scheduleMicrotask(_flush);
      }
    }
  }
}
