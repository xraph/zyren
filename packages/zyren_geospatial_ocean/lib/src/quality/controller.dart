import 'dart:async';
import 'package:zyren/zyren.dart';
import '../waves/sea_state.dart';
import '../rendering/wave_render_data.dart';
import '../rendering/wave_blend.dart';
import 'admission.dart';
import 'adaptive.dart';
import 'settings.dart';
import 'diagnostics.dart';
import '../queries/query.dart';
import 'package:zyren/rendering.dart' show GpuInspection, NativeFrameProfile;

/// A visual update under the host's presentation owner, never a physics step.
final class OceanPresentationFrame {
  final double seconds, transitionFraction;
  final Duration elapsed;
  const OceanPresentationFrame({
    required this.seconds,
    required this.elapsed,
    this.transitionFraction = 1,
  });
}

/// Register non-GPU cleanup as soon as it is acquired. Failed builds execute
/// these callbacks in reverse order, then close every resource in gpu.
final class OceanQualityBuildContext {
  final GpuScope gpu;
  final _cleanup = <FutureOr<void> Function()>[];
  bool _closed = false;
  Future<void>? _closing;
  OceanQualityBuildContext._(this.gpu);
  void onClose(FutureOr<void> Function() callback) {
    if (_closed) throw StateError('Quality build context closed.');
    _cleanup.add(callback);
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await _closeAll([
      for (final callback in _cleanup.reversed) callback,
      gpu.close,
    ]);
    _cleanup.clear();
  }
}

/// A prepared recipe. Build resources without attaching them to a live scene.
/// Include every owned payload in views/additionalPayloads. For a transition,
/// the planner receives the previous settings and can build common mesh morphs.
final class OceanQualityPlan<T extends Object> {
  final List<OceanViewAllocation> views;
  final Map<String, int> additionalPayloads;
  final Set<RenderFeature> requiredFeatures;
  final Set<String> activeEffects;
  final Future<T> Function(OceanQualityBuildContext, OceanWaveRenderInputs)
  build;
  final FutureOr<void> Function(T, OceanPresentationFrame)? prepareFrame;
  OceanQualityPlan({
    required this.build,
    Iterable<OceanViewAllocation> views = const [],
    Map<String, int> additionalPayloads = const {},
    Set<RenderFeature> requiredFeatures = const {},
    Set<String> activeEffects = const {},
    this.prepareFrame,
  }) : views = List.unmodifiable(views),
       additionalPayloads = Map.unmodifiable(additionalPayloads),
       requiredFeatures = Set.unmodifiable(requiredFeatures),
       activeEffects = Set.unmodifiable(activeEffects) {
    if (this.activeEffects.length > 64 ||
        this.activeEffects.any((s) => s.trim().isEmpty || s.length > 128)) {
      throw ArgumentError('Invalid active ocean effect names.');
    }
  }
}

typedef OceanQualityPlanner<T extends Object> =
    FutureOr<OceanQualityPlan<T>> Function(
      OceanQualitySettings settings,
      OceanQualitySettings? previous,
    );

/// Atomically publishes fully prepared visual resource sets. Read resources and
/// publicationRevision after awaiting setQuality/advance, then attach the current
/// set through the host frame owner. Do not keep using a retired set or render
/// concurrently with advance. The controller never owns a simulation clock.
final class OceanController<T extends Object> {
  final GpuScope _scope;
  final OceanSeaState state;
  final List<int> chartIds;
  final DeviceCapabilities capabilities;
  final OceanQualityPlanner<T> _plan;
  final int Function() _retainedBytes;
  final Duration transitionDuration;
  final OceanAdaptivePolicy adaptive;
  _Generation<T>? _current;
  _Transition<T>? _transition;
  bool _closed = false, _faulted = false;
  Future<void>? _pending, _closing;
  Object? lastFailure;
  final List<Object> _retirementFailures = [];
  int _unretiredBytes = 0, _publicationRevision = 0;
  Duration _elapsed = Duration.zero;
  double _seconds;
  OceanController._(
    this._scope,
    this.state,
    this.chartIds,
    this.capabilities,
    this._plan,
    this._retainedBytes,
    this.transitionDuration,
    this.adaptive,
    this._seconds,
  );
  String get seaStateRevision => state.revision;
  OceanQualitySettings get effectiveQuality => _current!.quality;
  T get resources => _transition?.value ?? _current!.value;
  OceanWaveRenderInputs get waves => _transition?.blend ?? _current!.waves;
  bool get isClosed => _closed || _scope.isClosed;
  bool get isReady =>
      !isClosed &&
      !_faulted &&
      _pending == null &&
      _current != null &&
      waves.isReady;
  bool get isTransitioning => _transition != null;
  double get transitionFraction => _transition?.blend.fraction ?? 1;
  int get publicationRevision => _publicationRevision;
  int get estimatedBytes =>
      (_transition?.ownedBytes ?? _current?.admission.candidateBytes ?? 0) +
      _unretiredBytes;
  OceanQualityAdmission get admission =>
      _transition?.admission ?? _current!.admission;
  Set<String> get activeEffects => Set.unmodifiable({
    'waves',
    ...(_transition?.plan ?? _current!.plan).activeEffects,
  });
  List<Object> get retirementFailures => List.unmodifiable(_retirementFailures);
  double get seconds => _seconds;

  static Future<OceanController<T>> create<T extends Object>(
    GpuScope parent, {
    required OceanSeaState state,
    required Iterable<int> chartIds,
    required DeviceCapabilities capabilities,
    required OceanQualitySettings quality,
    required OceanQualityPlanner<T> plan,
    Duration transitionDuration = const Duration(milliseconds: 400),
    OceanAdaptivePolicy? adaptive,
    double seconds = 0,
    int Function()? retainedBytes,
  }) async {
    final ids = chartIds.take(7).toList()..sort();
    if (ids.isEmpty ||
        ids.length > 6 ||
        ids.toSet().length != ids.length ||
        ids.any((id) => id < 0 || id > 5) ||
        transitionDuration.isNegative ||
        transitionDuration > const Duration(seconds: 5) ||
        !seconds.isFinite ||
        seconds.abs() > 1e12) {
      throw ArgumentError('Invalid ocean controller layout, duration or time.');
    }
    final result = OceanController<T>._(
      parent.createChild(label: 'ocean-controller'),
      state,
      List.unmodifiable(ids),
      capabilities,
      plan,
      retainedBytes ?? _noRetainedBytes,
      transitionDuration,
      adaptive ?? OceanAdaptivePolicy(),
      seconds,
    );
    try {
      await result._operate(() async {
        final recipe = await plan(quality, null);
        final admission = result._admit(
          quality,
          recipe,
          result._retainedBytes(),
        );
        final generation = await result._build(quality, recipe, admission);
        if (result.isClosed) {
          await generation.close();
          throw StateError('Ocean controller closed during creation.');
        }
        result._current = generation;
        result._publicationRevision++;
      });
      return result;
    } catch (_) {
      await result.close();
      rethrow;
    }
  }

  OceanQualityAdmission _admit(
    OceanQualitySettings settings,
    OceanQualityPlan<T> plan,
    int retained, {
    OceanQualitySettings? from,
    int? peakBudgetBytes,
  }) => OceanQualityAdmission.evaluate(
    settings: settings,
    state: state,
    chartIds: chartIds,
    capabilities: capabilities,
    views: plan.views,
    additionalPayloads: plan.additionalPayloads,
    additionalFeatures: plan.requiredFeatures,
    retainedBytes: retained,
    peakBudgetBytes: peakBudgetBytes,
    transitionFrom: from,
  );

  Future<_Generation<T>> _build(
    OceanQualitySettings quality,
    OceanQualityPlan<T> plan,
    OceanQualityAdmission admission,
  ) async {
    final root = _scope.createChild(label: 'ocean-quality-candidate');
    final context = OceanQualityBuildContext._(
      root.createChild(label: 'ocean-quality-visuals'),
    );
    try {
      final waves = await OceanWaveStream.create(
        root,
        state: state,
        chartIds: chartIds,
        resolution: quality.fftResolution,
        bandCount: admission.renderBands,
        seconds: _seconds,
        maxLogicalBytes: admission.peakBudgetBytes,
        retainedBytes:
            admission.peakBytes -
            OceanWaveStream.estimateBytes(
              quality.fftResolution,
              admission.renderBands,
              chartIds.length,
            ),
      );
      final value = await plan.build(context, waves);
      await plan.prepareFrame?.call(
        value,
        OceanPresentationFrame(seconds: _seconds, elapsed: _elapsed),
      );
      return _Generation(root, waves, context, quality, admission, plan, value);
    } catch (_) {
      await _retire([context.close, root.close], admission.candidateBytes);
      rethrow;
    }
  }

  Future<void> setQuality(OceanQualitySettings quality) =>
      _replace(quality, rebuild: false);

  /// Replan view topology or other presentation resources at the same quality.
  /// Uses the same admission, publication and transition rules as setQuality.
  Future<void> rebuild() => _replace(effectiveQuality, rebuild: true);

  Future<void> _replace(
    OceanQualitySettings quality, {
    required bool rebuild,
  }) => _operate(() async {
    if (_transition != null) {
      throw StateError('Finish the current quality transition first.');
    }
    final current = _current!;
    final before = current.quality.toJson();
    if (!rebuild &&
        quality.toJson().entries.every((e) => before[e.key] == e.value)) {
      return;
    }
    final external = _retainedBytes();
    final targetPlan = await _plan(quality, null);
    final fading = transitionDuration > Duration.zero;
    final transitionPlan = fading
        ? await _plan(quality, current.quality)
        : null;
    final peakBudget = current.quality.gpuBudgetBytes > quality.gpuBudgetBytes
        ? current.quality.gpuBudgetBytes
        : quality.gpuBudgetBytes;
    final targetAdmission = _admit(quality, targetPlan, 0);
    final waveBytes = OceanWaveStream.estimateBytes(
      quality.fftResolution,
      targetAdmission.renderBands,
      chartIds.length,
    );
    final transitionExtras = transitionPlan == null
        ? 0
        : _admit(
                quality.copyWith(gpuBudgetBytes: peakBudget),
                transitionPlan,
                0,
              ).candidateBytes -
              waveBytes;
    final admitted = _admit(
      quality,
      targetPlan,
      external + estimatedBytes + transitionExtras,
      from: fading ? current.quality : null,
      peakBudgetBytes: peakBudget,
    );
    _Generation<T>? candidate;
    _Transition<T>? transition;
    try {
      candidate = await _build(quality, targetPlan, admitted);
      if (transitionPlan != null) {
        final root = _scope.createChild(label: 'ocean-quality-transition');
        final context = OceanQualityBuildContext._(
          root.createChild(label: 'ocean-transition-visuals'),
        );
        try {
          final blend = await OceanWaveBlend.create(
            root,
            from: current.waves,
            to: candidate.waves,
            maxLogicalBytes: admitted.peakBudgetBytes,
            retainedBytes: admitted.peakBytes - admitted.transitionBytes,
          );
          final value = await transitionPlan.build(context, blend);
          await transitionPlan.prepareFrame?.call(
            value,
            OceanPresentationFrame(
              seconds: _seconds,
              elapsed: _elapsed,
              transitionFraction: 0,
            ),
          );
          transition = _Transition(
            root,
            context,
            blend,
            current,
            transitionPlan,
            value,
            admitted,
            admitted.peakBytes - external - _unretiredBytes,
            _elapsed,
          );
        } catch (_) {
          await _retire([
            context.close,
            root.close,
          ], admitted.transitionBytes + transitionExtras);
          rethrow;
        }
      }
      if (isClosed) {
        throw StateError('Ocean controller closed during preparation.');
      }
      _current = candidate;
      _transition = transition;
      _publicationRevision++;
      if (transition == null) {
        await _retire([current.close], current.admission.candidateBytes);
      }
    } catch (_) {
      if (transition != null) {
        await _retire([
          transition.close,
        ], admitted.transitionBytes + transitionExtras);
      }
      if (candidate != null) {
        await _retire([candidate.close], candidate.admission.candidateBytes);
      }
      rethrow;
    }
  });

  Future<void> advance({required double seconds, required Duration elapsed}) =>
      _operate(() async {
        if (!seconds.isFinite || seconds.abs() > 1e12 || elapsed < _elapsed) {
          throw ArgumentError('Invalid ocean presentation time.');
        }
        try {
          final current = _current!, transition = _transition;
          await current.waves.update(seconds);
          if (transition != null) {
            await transition.from.waves.update(seconds);
            final fraction =
                ((elapsed - transition.started).inMicroseconds /
                        transitionDuration.inMicroseconds)
                    .clamp(0.0, 1.0);
            await transition.blend.update(fraction);
            final frame = OceanPresentationFrame(
              seconds: seconds,
              elapsed: elapsed,
              transitionFraction: fraction,
            );
            if (fraction < 1) {
              await transition.plan.prepareFrame?.call(transition.value, frame);
            } else {
              await current.plan.prepareFrame?.call(current.value, frame);
              if (isClosed) {
                throw StateError('Ocean controller closed during update.');
              }
              _transition = null;
              _publicationRevision++;
              await _retire([
                transition.close,
                transition.from.close,
              ], transition.ownedBytes - current.admission.candidateBytes);
            }
          } else {
            await current.plan.prepareFrame?.call(
              current.value,
              OceanPresentationFrame(seconds: seconds, elapsed: elapsed),
            );
          }
          _seconds = seconds;
          _elapsed = elapsed;
          _faulted = false;
        } catch (_) {
          _faulted = true;
          rethrow;
        }
      });

  /// Samples the opt-in policy. A recommendation still goes through normal
  /// admission. Custom profiles and in-progress transitions are left unchanged.
  Future<bool> considerQuality({
    required Duration elapsed,
    required double? frameMilliseconds,
  }) async {
    if (!isReady || isTransitioning || effectiveQuality.preset == null) {
      return false;
    }
    final next = adaptive.observe(
      current: effectiveQuality.preset!,
      elapsed: elapsed,
      frameMilliseconds: frameMilliseconds,
    );
    if (next == null) return false;
    await setQuality(next.settings);
    return true;
  }

  /// Caller-supplied pass measurements describe installed extensions. Native
  /// inspection and presentation profiles retain their whole-device/frame scope.
  OceanDiagnostics diagnostics({
    GpuInspection? device,
    NativeFrameProfile? presentationFrame,
    OceanSample? lastQuery,
    int? patchCount,
    int? vertexCount,
    Iterable<OceanPassMeasurement> passes = const [],
  }) {
    OceanPassMeasurement wavePass(String name, OceanWaveStream stream) {
      final measured = stream.revision > 0 || stream.lastFailure != null;
      return OceanPassMeasurement(
        name: name,
        status: stream.lastFailure != null
            ? OceanPassStatus.failed
            : measured
            ? OceanPassStatus.executed
            : OceanPassStatus.unavailable,
        hostElapsed: measured ? stream.lastHostTime : null,
        dispatches: stream.lastFailure == null && measured
            ? stream.lastDispatches
            : null,
      );
    }

    final transition = _transition;
    return OceanDiagnostics(
      status: isClosed
          ? 'closed'
          : _pending != null
          ? 'busy'
          : isReady
          ? 'ready'
          : 'faulted',
      seaStateRevision: seaStateRevision,
      quality: effectiveQuality,
      admission: admission,
      ownedPayloadBytes: estimatedBytes,
      publicationRevision: publicationRevision,
      seconds: seconds,
      transitionFraction: transitionFraction,
      activeEffects: activeEffects,
      patchCount: patchCount,
      vertexCount: vertexCount,
      viewCount: (transition?.plan ?? _current!.plan).views.length,
      device: device,
      presentationFrame: presentationFrame,
      lastQuery: lastQuery,
      lastFailure: lastFailure,
      retirementFailures: retirementFailures,
      passes: [
        wavePass('waves.current', _current!.waves),
        if (transition != null)
          wavePass('waves.previous', transition.from.waves),
        if (transition != null)
          OceanPassMeasurement(
            name: 'waves.transition',
            status: transition.blend.lastFailure == null
                ? OceanPassStatus.executed
                : OceanPassStatus.failed,
            hostElapsed: transition.blend.lastHostTime,
            dispatches: transition.blend.lastFailure == null
                ? transition.blend.lastDispatches
                : null,
          ),
        ...passes.take(129),
      ],
    );
  }

  Future<void> _operate(Future<void> Function() work) async {
    if (isClosed || _pending != null) {
      throw StateError('Ocean controller is closed or busy.');
    }
    final done = Completer<void>();
    _pending = done.future;
    try {
      await work();
      lastFailure = null;
    } catch (error) {
      lastFailure = error;
      rethrow;
    } finally {
      _pending = null;
      done.complete();
    }
  }

  Future<void> _retire(List<FutureOr<void> Function()> work, int bytes) async {
    try {
      await _closeAll(work);
    } catch (error) {
      _unretiredBytes += bytes;
      if (_retirementFailures.length == 16) _retirementFailures.removeAt(0);
      _retirementFailures.add(error);
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await _pending;
    final transition = _transition, current = _current;
    await _closeAll([
      if (transition != null) transition.close,
      if (transition != null) transition.from.close,
      if (current != null) current.close,
      _scope.close,
      if (_retirementFailures.isNotEmpty)
        () => throw ScopeCleanupException(_retirementFailures),
    ]);
  }
}

int _noRetainedBytes() => 0;
Future<void> _closeAll(Iterable<FutureOr<void> Function()> callbacks) async {
  final errors = <Object>[];
  for (final callback in callbacks) {
    try {
      await callback();
    } catch (e) {
      errors.add(e);
    }
  }
  if (errors.isNotEmpty) throw ScopeCleanupException(errors);
}

final class _Generation<T extends Object> {
  final GpuScope root;
  final OceanWaveStream waves;
  final OceanQualityBuildContext context;
  final OceanQualitySettings quality;
  final OceanQualityAdmission admission;
  final OceanQualityPlan<T> plan;
  final T value;
  Future<void>? _closing;
  _Generation(
    this.root,
    this.waves,
    this.context,
    this.quality,
    this.admission,
    this.plan,
    this.value,
  );
  Future<void> close() =>
      _closing ??= _closeAll([context.close, waves.close, root.close]);
}

final class _Transition<T extends Object> {
  final GpuScope root;
  final OceanQualityBuildContext context;
  final OceanWaveBlend blend;
  final _Generation<T> from;
  final OceanQualityPlan<T> plan;
  final T value;
  final OceanQualityAdmission admission;
  final int ownedBytes;
  final Duration started;
  Future<void>? _closing;
  _Transition(
    this.root,
    this.context,
    this.blend,
    this.from,
    this.plan,
    this.value,
    this.admission,
    this.ownedBytes,
    this.started,
  );
  Future<void> close() =>
      _closing ??= _closeAll([context.close, blend.close, root.close]);
}
