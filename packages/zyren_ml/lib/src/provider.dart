import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'manifest.dart';
import 'model_cache.dart';
import 'result.dart';
import 'runtime.dart';
import 'tensor.dart';
import 'worker.dart';

final class MlProviderReport {
  MlProviderReport({
    required this.requestedProvider,
    required this.status,
    this.actualProvider,
    this.unsupportedOperators,
    this.message,
    this.modelLoad,
    this.coldRun,
    this.warmRun,
    this.numericalProbeVerified = false,
    this.nativeArenaBytes,
    this.partition,
    this.selection,
    this.cpuRoundTripMedian,
    this.providerRoundTripMedian,
    this.cpuRoundTripP95,
    this.providerRoundTripP95,
    this.sequenceSteps = 0,
    this.timingBenefitVerified = false,
  }) : allocationLimits = const {
         'boundaryTensorBytes': mlMaxTensorBytes,
         'residentModelBytes': 64 * 1024 * 1024,
         'residentModels': 8,
       };
  final String requestedProvider;
  final String? actualProvider;
  final MlRunStatus status;

  /// Null means the graph was not successfully probed or the loader did not
  /// provide a structured unsupported-operator list. An empty list means load succeeded.
  final List<String>? unsupportedOperators;
  final String? message;
  final Duration? modelLoad;
  final Duration? coldRun;
  final Duration? warmRun;
  final bool numericalProbeVerified;
  final Map<String, int> allocationLimits;
  final int? nativeArenaBytes;
  final MlProviderPartition? partition;
  final MlProviderSelection? selection;
  final Duration? cpuRoundTripMedian, providerRoundTripMedian;
  final Duration? cpuRoundTripP95, providerRoundTripP95;
  final int sequenceSteps;
  final bool timingBenefitVerified;

  /// CoreML may internally choose CPU, GPU or Neural Engine. EP assignment alone
  /// does not identify the hardware that executed an MLProgram.
  String? get acceleratedHardware => null;
}

/// Probes the exact graph through the worker, retaining CPU as an explicit choice.
final class MlProviderProbe {
  const MlProviderProbe();
  Future<MlProviderReport> probe({
    required MlModelManifest model,
    required ModelAssetResolver resolver,
    required MlTensorMap inputs,
    MlTensorMap? referenceOutputs,
    String provider = 'cpu',
    double tolerance = 1e-5,
    double relativeTolerance = 1e-4,
    Iterable<MlProviderProbeStep>? sequence,
    int warmSamples = 64,
  }) async {
    if (!tolerance.isFinite || tolerance < 0) {
      throw ArgumentError(
        'Numerical tolerance must be finite and nonnegative.',
      );
    }
    if (provider == 'coreml' && referenceOutputs != null) {
      if (tolerance > 1e-5 ||
          !relativeTolerance.isFinite ||
          relativeTolerance < 0 ||
          relativeTolerance > 1e-4) {
        throw ArgumentError(
          'CoreML qualification requires atol<=1e-5 and rtol<=1e-4.',
        );
      }
      if (warmSamples < 32 || warmSamples > 128) {
        throw ArgumentError(
          'Provider timing requires 32..128 paired warm samples.',
        );
      }
      return _coremlProbe(
        model,
        resolver,
        inputs,
        referenceOutputs,
        tolerance,
        relativeTolerance,
        sequence,
        warmSamples,
      );
    }
    if (provider != 'cpu') {
      return MlProviderReport(
        requestedProvider: provider,
        status: MlRunStatus.unsupported,
        message: 'Provider $provider is not qualified for this graph/device.',
      );
    }
    if (!tolerance.isFinite || tolerance < 0) {
      throw ArgumentError(
        'Numerical tolerance must be finite and nonnegative.',
      );
    }
    final cache = MlModelCache(worker: MlWorker(), resolver: resolver);
    MlModelLease? lease;
    try {
      lease = await cache.acquire(model);
      final cold = await lease.run(inputs);
      if (cold.status != MlRunStatus.ok) {
        return MlProviderReport(
          requestedProvider: provider,
          actualProvider: 'cpu',
          status: cold.status,
          message: cold.message,
          unsupportedOperators: const [],
          modelLoad: lease.loadTime,
        );
      }
      final warm = await lease.run(inputs);
      final expected = referenceOutputs ?? cold.tensors;
      final matches =
          warm.status == MlRunStatus.ok &&
          _matches(cold.tensors, expected, tolerance) &&
          _matches(warm.tensors, expected, tolerance);
      return MlProviderReport(
        requestedProvider: provider,
        actualProvider: 'cpu',
        status: matches ? MlRunStatus.ok : MlRunStatus.failed,
        unsupportedOperators: const [],
        modelLoad: lease.loadTime,
        coldRun: cold.elapsed,
        warmRun: warm.elapsed,
        numericalProbeVerified: referenceOutputs != null && matches,
        message: matches
            ? null
            : 'Graph output differs from numerical reference.',
      );
    } on MlLoadException catch (e) {
      return MlProviderReport(
        requestedProvider: provider,
        status: e.status,
        message: e.message,
      );
    } catch (e) {
      return MlProviderReport(
        requestedProvider: provider,
        status: MlRunStatus.failed,
        message: e.toString(),
      );
    } finally {
      if (lease != null) await cache.release(lease);
      await cache.close();
    }
  }
}

bool _matches(
  MlTensorMap actual,
  MlTensorMap expected,
  double tolerance, [
  double relativeTolerance = 0,
]) {
  if (actual.length != expected.length) return false;
  for (final entry in expected.entries) {
    final tensor = actual[entry.key];
    if (tensor == null ||
        tensor.dtype != entry.value.dtype ||
        tensor.shape.join(',') != entry.value.shape.join(',') ||
        !tensor.isFinite ||
        !entry.value.isFinite) {
      return false;
    }
    if (tensor.dtype == MlDtype.float32) {
      final a = tensor.float32Values, b = entry.value.float32Values;
      for (var i = 0; i < a.length; i++) {
        if ((a[i] - b[i]).abs() > tolerance + relativeTolerance * b[i].abs()) {
          return false;
        }
      }
    } else {
      final a = tensor.bytes, b = entry.value.bytes;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
    }
  }
  return true;
}

/// A model, shape and device-bound capability minted only by a successful probe.
/// It is intentionally not serializable. Reprobe after fifteen minutes.
final class MlProviderSelection {
  MlProviderSelection._(MlModelManifest model, MlTensorMap inputs)
    : modelHash = model.sha256,
      _manifest = model.encode(),
      inputShapes = Map.unmodifiable(
        inputs.map(
          (key, value) => MapEntry(key, List<int>.unmodifiable(value.shape)),
        ),
      ),
      _device = _deviceIdentity(),
      _age = Stopwatch()..start();
  final String modelHash;
  final String _manifest, _device;
  final Stopwatch _age;
  final Map<String, List<int>> inputShapes;
  String get provider => 'coreml';
  Duration get validFor {
    final remaining = const Duration(minutes: 15) - _age.elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool matches({required MlModelManifest model}) =>
      model.sha256 == modelHash &&
      model.encode() == _manifest &&
      _deviceIdentity() == _device &&
      _age.elapsed < const Duration(minutes: 15);
  bool accepts(MlTensorMap inputs) =>
      _age.elapsed < const Duration(minutes: 15) &&
      inputs.length == inputShapes.length &&
      inputShapes.entries.every(
        (e) => inputs[e.key]?.shape.join(',') == e.value.join(','),
      );
}

// Unexported authority type, with no public constructor. Workers require it to
// run an unqualified graph exclusively for qualification, never production.
final class MlProviderProbeAuthority {
  const MlProviderProbeAuthority._();
  String get provider => 'coreml';
}

final class MlProviderProbeStep {
  MlProviderProbeStep({
    required MlTensorMap inputs,
    required MlTensorMap referenceOutputs,
    this.resetState = false,
  }) : inputs = Map.unmodifiable(inputs),
       referenceOutputs = Map.unmodifiable(referenceOutputs);
  final MlTensorMap inputs, referenceOutputs;
  final bool resetState;
}

/// Optimized kernel identities recorded by ORT, not original graph node counts.
final class MlProviderPartition {
  MlProviderPartition._(Map<String, List<String>> kernels)
    : kernels = Map.unmodifiable(
        kernels.map(
          (key, value) => MapEntry(key, List<String>.unmodifiable(value)),
        ),
      );
  final Map<String, List<String>> kernels;
  bool get exclusivelyCoreMl =>
      kernels.length == 1 &&
      (kernels['CoreMLExecutionProvider']?.isNotEmpty ?? false);
}

String _deviceIdentity() =>
    '${Platform.operatingSystem}:${Platform.operatingSystemVersion}:'
    '${Platform.localHostname}:${Abi.current()}:${MlRuntime.runtimeVersion}';

Future<MlProviderReport> _coremlProbe(
  MlModelManifest model,
  ModelAssetResolver resolver,
  MlTensorMap inputs,
  MlTensorMap reference,
  double tolerance,
  double relativeTolerance,
  Iterable<MlProviderProbeStep>? sequence,
  int warmSamples,
) async {
  if (!Platform.isMacOS && !Platform.isIOS) {
    return MlProviderReport(
      requestedProvider: 'coreml',
      status: MlRunStatus.unsupported,
      message: 'CoreML requires the pinned Apple runtime.',
    );
  }
  final cpu = MlWorker();
  final provider = MlWorker.forProviderProbe(
    const MlProviderProbeAuthority._(),
  );
  Duration? load, coldTime, warmTime;
  MlProviderPartition? partition;
  var steps = 0;
  var numerics = false;
  String? actual;
  try {
    if (!const MlRuntime().availableProviders.contains(
      'CoreMLExecutionProvider',
    )) {
      return MlProviderReport(
        requestedProvider: 'coreml',
        status: MlRunStatus.unsupported,
        message: 'Pinned runtime has no CoreML execution provider.',
      );
    }
    final resolved = await resolver(model.modelFile);
    if (resolved.isEmpty || resolved.length > model.maxModelBytes) {
      throw const MlLoadException(
        MlRunStatus.invalid,
        'Provider probe model exceeds manifest byte bounds.',
      );
    }
    if (resolved.length > 32 * 1024 * 1024) {
      throw const MlLoadException(
        MlRunStatus.unavailable,
        'Comparative provider probe exceeds its shared 64MiB model admission limit.',
      );
    }
    final bytes = Uint8List.fromList(resolved);
    await cpu.load(model, bytes);
    load = await provider.load(model, bytes);
    final cold = await provider.run(model.sha256, inputs, const MlRunOptions());
    actual = 'coreml';
    coldTime = cold.elapsed;
    final warm = await provider.run(model.sha256, inputs, const MlRunOptions());
    warmTime = warm.elapsed;
    final baseline = await cpu.run(model.sha256, inputs, const MlRunOptions());
    if (cold.status != MlRunStatus.ok ||
        warm.status != MlRunStatus.ok ||
        baseline.status != MlRunStatus.ok ||
        !_matches(cold.tensors, reference, tolerance, relativeTolerance) ||
        !_matches(warm.tensors, reference, tolerance, relativeTolerance) ||
        !_matches(baseline.tensors, reference, tolerance, relativeTolerance)) {
      throw StateError(
        'Cold/warm CPU and CoreML outputs did not match the independent reference.',
      );
    }
    final profile = await provider.finishProviderProbe(model.sha256);
    partition = MlProviderPartition._(
      (profile['kernels'] as Map).map(
        (key, value) => MapEntry(key as String, (value as List).cast<String>()),
      ),
    );
    if (!partition.exclusivelyCoreMl) {
      throw StateError(
        'Profile has missing CoreML kernels or non-CoreML partition assignments.',
      );
    }
    MlTensorMap? cpuState, providerState;
    if (sequence != null) {
      for (final step in sequence) {
        if (++steps > 4096 ||
            step.inputs.length != inputs.length ||
            inputs.entries.any(
              (e) =>
                  step.inputs[e.key]?.shape.join(',') !=
                  e.value.shape.join(','),
            )) {
          throw StateError(
            'Sequence exceeds 4096 steps or qualified input shapes.',
          );
        }
        MlTensorMap withState(MlTensorMap? previous) => {
          ...step.inputs,
          if (!step.resetState && previous != null)
            for (final entry in model.recurrent.entries)
              entry.key: previous[entry.value]!,
        };
        final a = await cpu.run(
          model.sha256,
          withState(cpuState),
          const MlRunOptions(),
        );
        final b = await provider.run(
          model.sha256,
          withState(providerState),
          const MlRunOptions(),
        );
        cpuState = a.tensors;
        providerState = b.tensors;
        if (a.status != MlRunStatus.ok ||
            b.status != MlRunStatus.ok ||
            !_matches(
              a.tensors,
              step.referenceOutputs,
              tolerance,
              relativeTolerance,
            ) ||
            !_matches(
              b.tensors,
              step.referenceOutputs,
              tolerance,
              relativeTolerance,
            )) {
          throw StateError(
            'Independent sequence reference mismatch at step $steps.',
          );
        }
      }
    }
    if (model.recurrent.isNotEmpty && steps < 1000) {
      throw StateError(
        'Recurrent CoreML qualification requires 1000 independent sequence steps.',
      );
    }
    numerics = true;
    final cpuTimes = <int>[], providerTimes = <int>[];
    Future<void> timed(MlWorker worker, List<int> samples) async {
      final watch = Stopwatch()..start();
      final result = await worker.run(
        model.sha256,
        inputs,
        const MlRunOptions(),
      );
      samples.add(watch.elapsedMicroseconds);
      if (result.status != MlRunStatus.ok ||
          !_matches(result.tensors, reference, tolerance, relativeTolerance)) {
        throw StateError(
          'Numerical mismatch during the transfer-inclusive timing probe.',
        );
      }
    }

    for (var i = 0; i < warmSamples; i++) {
      if (i.isEven) {
        await timed(cpu, cpuTimes);
        await timed(provider, providerTimes);
      } else {
        await timed(provider, providerTimes);
        await timed(cpu, cpuTimes);
      }
    }
    int percentile(List<int> source, double p) {
      final sorted = source.toList()..sort();
      return sorted[((sorted.length - 1) * p).ceil()];
    }

    final c50 = percentile(cpuTimes, .5), p50 = percentile(providerTimes, .5);
    final c95 = percentile(cpuTimes, .95), p95 = percentile(providerTimes, .95);
    bool faster(List<int> a, List<int> b) =>
        percentile(b, .5) < percentile(a, .5) * .95;
    final half = warmSamples ~/ 2;
    final benefit =
        p50 < c50 * .95 &&
        p95 < c95 * .95 &&
        p95 <= p50 * 3 &&
        faster(cpuTimes.sublist(0, half), providerTimes.sublist(0, half)) &&
        faster(cpuTimes.sublist(half), providerTimes.sublist(half));
    return MlProviderReport(
      requestedProvider: 'coreml',
      actualProvider: actual,
      status: MlRunStatus.ok,
      unsupportedOperators: const [],
      modelLoad: load,
      coldRun: coldTime,
      warmRun: warmTime,
      partition: partition,
      numericalProbeVerified: true,
      sequenceSteps: steps,
      timingBenefitVerified: benefit,
      cpuRoundTripMedian: Duration(microseconds: c50),
      providerRoundTripMedian: Duration(microseconds: p50),
      cpuRoundTripP95: Duration(microseconds: c95),
      providerRoundTripP95: Duration(microseconds: p95),
      selection: benefit ? MlProviderSelection._(model, inputs) : null,
      message: benefit
          ? null
          : 'CoreML passed the graph/numerical probe but no stable timing benefit was demonstrated.',
    );
  } on MlLoadException catch (e) {
    return MlProviderReport(
      requestedProvider: 'coreml',
      actualProvider: actual,
      status: e.status,
      message: e.message,
      modelLoad: load,
      coldRun: coldTime,
      warmRun: warmTime,
      partition: partition,
      sequenceSteps: steps,
    );
  } catch (e) {
    return MlProviderReport(
      requestedProvider: 'coreml',
      actualProvider: actual,
      status: MlRunStatus.failed,
      message: e.toString(),
      modelLoad: load,
      coldRun: coldTime,
      warmRun: warmTime,
      partition: partition,
      sequenceSteps: steps,
      numericalProbeVerified: numerics,
    );
  } finally {
    await Future.wait([cpu.close(), provider.close()]);
  }
}
