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
  }) async {
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

bool _matches(MlTensorMap actual, MlTensorMap expected, double tolerance) {
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
        if ((a[i] - b[i]).abs() > tolerance) return false;
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
