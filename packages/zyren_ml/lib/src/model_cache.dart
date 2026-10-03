import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'diagnostics.dart';
import 'manifest.dart';
import 'result.dart';
import 'runtime.dart';
import 'tensor.dart';
import 'worker.dart';

/// Resolves identical filenames in separate, content-pinned model artifacts.
typedef ModelManifestResolver =
    Future<Uint8List> Function(MlModelManifest model);

final class MlCapacityException implements Exception {
  const MlCapacityException(this.message);
  final String message;
  @override
  String toString() => 'MlCapacityException: $message';
}

final class MlModelLease {
  MlModelLease._(this._owner, this._entry, this.newlyLoaded);
  final MlModelCache _owner;
  final _Resident _entry;
  bool _released = false;
  final bool newlyLoaded;
  String get modelHash => _entry.model.sha256;
  Duration get loadTime => _entry.loadTime;
  Future<MlRunResult> run(
    MlTensorMap tensors, [
    MlRunOptions options = const MlRunOptions(),
  ]) => _owner._run(this, tensors, options);
}

final class _Resident {
  _Resident(this.model, this.weights, this.loadTime);
  final MlModelManifest model;
  final int weights;
  final Duration loadTime;
  var leases = 0;
  var inFlight = 0;
  var recency = 0;
  var hasRun = false;
}

/// Retains native sessions and in-flight references, never model asset bytes.
final class MlModelCache {
  MlModelCache({
    this.resolver,
    this.manifestResolver,
    MlInferenceWorker? worker,
    this.maxResidentModels = 8,
    this.maxModelWeightsBytes = 64 * 1024 * 1024,
  }) : worker = worker ?? MlWorker() {
    if ((resolver == null) == (manifestResolver == null)) {
      throw ArgumentError('Provide one model asset or manifest resolver.');
    }
    if (maxResidentModels <= 0 ||
        maxResidentModels > 8 ||
        maxModelWeightsBytes <= 0 ||
        maxModelWeightsBytes > 64 * 1024 * 1024) {
      throw ArgumentError(
        'Cache limits exceed the eight-model/64 MiB contract.',
      );
    }
  }
  final ModelAssetResolver? resolver;
  final ModelManifestResolver? manifestResolver;
  final MlInferenceWorker worker;
  final int maxResidentModels;
  final int maxModelWeightsBytes;
  final _residents = <String, _Resident>{};
  final _jobs = <Future<MlRunResult>>{};
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  var _closed = false;
  var _recency = 0;
  var _pendingAcquires = 0;

  MlDiagnostics get diagnostics => MlDiagnostics(
    residentModels: _residents.length,
    modelWeightsBytes: _residents.values.fold(0, (n, e) => n + e.weights),
    leaseReferences: _residents.values.fold(0, (n, e) => n + e.leases),
    inFlightReferences: _residents.values.fold(0, (n, e) => n + e.inFlight),
  );

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<MlModelLease> acquire(MlModelManifest model) {
    if (_closed) {
      return Future.error(
        const MlLoadException(
          MlRunStatus.unavailable,
          'Model cache is closed.',
        ),
      );
    }
    if (_pendingAcquires >= 64) {
      return Future.error(
        const MlCapacityException('Pending model acquisitions exceed 64.'),
      );
    }
    _pendingAcquires++;
    return _serial(() async {
      try {
        if (_closed) {
          throw const MlLoadException(
            MlRunStatus.unavailable,
            'Model cache is closed.',
          );
        }
        var entry = _residents[model.sha256];
        final newlyLoaded = entry == null;
        if (entry != null) {
          if (entry.model.encode() != model.encode()) {
            throw const MlLoadException(
              MlRunStatus.invalid,
              'Duplicate model hash has a different manifest pin.',
            );
          }
        } else {
          Uint8List bytes;
          try {
            bytes = Uint8List.fromList(
              await (manifestResolver != null
                  ? manifestResolver!(model)
                  : resolver!(model.modelFile)),
            );
          } catch (e) {
            throw MlLoadException(
              MlRunStatus.unavailable,
              'Model resolution failed: $e',
            );
          }
          if (_closed) {
            throw const MlLoadException(
              MlRunStatus.unavailable,
              'Model cache closed during asset resolution.',
            );
          }
          // Check this model before evicting any currently useful native session.
          if (bytes.length > maxModelWeightsBytes ||
              bytes.length > model.maxModelBytes) {
            throw const MlCapacityException(
              'Model weights exceed the cache or manifest limit.',
            );
          }
          if (bytes.isEmpty ||
              crypto.sha256.convert(bytes).toString() != model.sha256) {
            throw const MlLoadException(
              MlRunStatus.invalid,
              'Model bytes differ from their pinned hash.',
            );
          }
          while (_residents.length >= maxResidentModels ||
              diagnostics.modelWeightsBytes + bytes.length >
                  maxModelWeightsBytes) {
            final idle =
                _residents.values
                    .where((e) => e.leases == 0 && e.inFlight == 0)
                    .toList()
                  ..sort((a, b) => a.recency.compareTo(b.recency));
            if (idle.isEmpty) {
              throw const MlCapacityException(
                'Resident models are leased or in flight.',
              );
            }
            final evicted = idle.first;
            await worker.release(evicted.model.sha256);
            _residents.remove(evicted.model.sha256);
          }
          final elapsed = await worker.load(model, bytes);
          if (_closed) {
            await worker.release(model.sha256);
            throw const MlLoadException(
              MlRunStatus.unavailable,
              'Model cache closed during native loading.',
            );
          }
          entry = _Resident(model, bytes.length, elapsed);
          _residents[model.sha256] = entry;
        }
        entry.leases++;
        entry.recency = _recency++;
        return MlModelLease._(this, entry, newlyLoaded);
      } finally {
        _pendingAcquires--;
      }
    });
  }

  Future<void> release(MlModelLease lease) async {
    if (!identical(lease._owner, this)) {
      throw ArgumentError('Lease belongs to another cache.');
    }
    if (lease._released) return;
    lease._released = true;
    lease._entry.leases--;
    lease._entry.recency = _recency++;
  }

  Future<MlRunResult> _run(
    MlModelLease lease,
    MlTensorMap tensors,
    MlRunOptions options,
  ) {
    if (_closed || lease._released) {
      return Future.value(
        MlRunResult(
          MlRunStatus.unavailable,
          message: 'Model lease is closed.',
          requestId: options.requestId,
        ),
      );
    }
    final entry = lease._entry;
    entry.inFlight++;
    entry.hasRun = true;
    late final Future<MlRunResult> job;
    job =
        Future<MlRunResult>.sync(
          () => worker.run(entry.model.sha256, tensors, options),
        ).whenComplete(() {
          entry.inFlight--;
          entry.recency = _recency++;
          _jobs.remove(job);
        });
    _jobs.add(job);
    return job;
  }

  bool isCold(MlModelLease lease) => !lease._entry.hasRun;

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await _tail;
    await Future.wait(
      _jobs.toList().map(
        (job) => job.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
    await worker.close();
    _residents.clear();
  }
}
