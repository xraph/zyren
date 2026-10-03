import 'dart:async';
import 'dart:typed_data';

import 'diagnostics.dart';
import 'manifest.dart';
import 'model_cache.dart';
import 'result.dart';
import 'tensor.dart';

enum MlOutcomeStatus {
  ok,
  invalid,
  unsupported,
  unavailable,
  cancelled,
  failed,
  expired,
  capacity,
}

/// Actor metadata stays on the host; the worker receives tensors and model pins.
final class MlRequest {
  MlRequest({
    required this.id,
    required this.model,
    required this.modelHash,
    required MlTensorMap tensors,
    required this.actorToken,
    required this.observationTick,
    required this.applicationTick,
    required this.deadlineTick,
    this.deadline,
    this.cancellation,
  }) : tensors = Map.unmodifiable(tensors);
  final String id;
  final MlModelManifest model;
  final String modelHash;
  final MlTensorMap tensors;
  final Object? actorToken;
  final int observationTick;
  final int applicationTick;
  final int deadlineTick;
  final DateTime? deadline;
  final MlCancellationToken? cancellation;
  int get byteLength => tensors.values.fold(0, (n, t) => n + t.byteLength);
}

final class MlOutcome {
  MlOutcome({
    required this.status,
    required MlRequest request,
    required this.completedTick,
    MlTensorMap tensors = const {},
    this.message,
    this.timing = const MlTiming(),
  }) : requestId = request.id,
       modelHash = request.modelHash,
       actorToken = request.actorToken,
       observationTick = request.observationTick,
       applicationTick = request.applicationTick,
       deadlineTick = request.deadlineTick,
       tensors = Map.unmodifiable(tensors);
  final MlOutcomeStatus status;
  final String requestId;
  final String modelHash;
  final Object? actorToken;
  final int observationTick;
  final int applicationTick;
  final int deadlineTick;
  final int completedTick;
  final MlTensorMap tensors;
  final String? message;
  final MlTiming timing;
}

/// Compact published slots keep their original native output-row index.
final class MlBatchMap {
  MlBatchMap(List<String> slotRequestIds, List<int> nativeSlotIndices)
    : slotRequestIds = List.unmodifiable(slotRequestIds),
      nativeSlotIndices = List.unmodifiable(nativeSlotIndices) {
    if (slotRequestIds.length != nativeSlotIndices.length ||
        slotRequestIds.toSet().length != slotRequestIds.length ||
        nativeSlotIndices.toSet().length != nativeSlotIndices.length) {
      throw ArgumentError('Batch maps need unique corresponding slots.');
    }
  }
  final List<String> slotRequestIds;
  final List<int> nativeSlotIndices;
}

final class MlBatchReceipt {
  MlBatchReceipt(this.map, Map<String, MlOutcome> results)
    : results = Map.unmodifiable(results);
  final MlBatchMap map;
  final Map<String, MlOutcome> results;
}

final class _Queued {
  _Queued(this.request);
  final MlRequest request;
  final completion = Completer<MlOutcome>();
  final age = Stopwatch()..start();
  bool cancelled = false;
  bool running = false;
  bool get isCancelled =>
      cancelled || (request.cancellation?.isCancelled ?? false);
}

/// Bounded queue and batch scheduling; native execution always belongs to cache workers.
final class MlScheduler {
  MlScheduler({
    required this.cache,
    required this.currentTick,
    this.maxQueuedRequests = 64,
    this.maxQueuedBytes = 32 * 1024 * 1024,
    this.maxBatchSlots = 64,
    this.maxInFlightBatches = 1,
    this.batchWait = const Duration(milliseconds: 2),
  }) {
    if (maxQueuedRequests <= 0 ||
        maxQueuedRequests > 64 ||
        maxQueuedBytes <= 0 ||
        maxQueuedBytes > 32 * 1024 * 1024 ||
        maxBatchSlots <= 0 ||
        maxBatchSlots > 64 ||
        maxInFlightBatches <= 0 ||
        maxInFlightBatches > 8 ||
        batchWait.isNegative ||
        batchWait > const Duration(milliseconds: 100)) {
      throw ArgumentError(
        'Scheduler limits exceed the bounded admission contract.',
      );
    }
  }
  final MlModelCache cache;
  final int Function() currentTick;
  final int maxQueuedRequests;
  final int maxQueuedBytes;
  final int maxBatchSlots;
  final int maxInFlightBatches;
  final Duration batchWait;
  final _queue = <_Queued>[];
  final _active = <String, _Queued>{};
  final _jobs = <Future<void>>{};
  final _batches = StreamController<MlBatchReceipt>.broadcast(sync: true);
  Timer? _timer;
  var _queuedBytes = 0;
  var _inFlightBytes = 0;
  bool _closed = false;
  Future<void>? _closing;
  Stream<MlBatchReceipt> get batches => _batches.stream;

  MlDiagnostics get diagnostics {
    final models = cache.diagnostics;
    return MlDiagnostics(
      queuedRequests: _queue.length,
      queuedTensorBytes: _queuedBytes,
      inFlightBatches: _jobs.length,
      inFlightTensorBytes: _inFlightBytes,
      residentModels: models.residentModels,
      modelWeightsBytes: models.modelWeightsBytes,
      leaseReferences: models.leaseReferences,
      inFlightReferences: models.inFlightReferences,
    );
  }

  Future<MlOutcome> submit(MlRequest request) {
    MlOutcome rejection(MlOutcomeStatus status, String message) => MlOutcome(
      status: status,
      request: request,
      completedTick: currentTick(),
      message: message,
    );
    if (_closed) {
      return Future.value(
        rejection(MlOutcomeStatus.unavailable, 'Scheduler is closed.'),
      );
    }
    if (_expired(request)) {
      return Future.value(
        rejection(MlOutcomeStatus.expired, 'Request deadline has passed.'),
      );
    }
    if (request.cancellation?.isCancelled ?? false) {
      return Future.value(
        rejection(MlOutcomeStatus.cancelled, 'Request cancelled.'),
      );
    }
    if (request.id.isEmpty ||
        _active.containsKey(request.id) ||
        request.modelHash != request.model.sha256 ||
        request.observationTick < 0 ||
        request.applicationTick < request.observationTick ||
        request.deadlineTick < request.observationTick ||
        request.tensors.length != request.model.inputs.length ||
        request.model.inputs.any(
          (s) =>
              !request.tensors.containsKey(s.name) ||
              !s.accepts(request.tensors[s.name]!, requireFinite: false),
        )) {
      return Future.value(
        rejection(
          MlOutcomeStatus.invalid,
          'Request identity, model pin or input schema is invalid.',
        ),
      );
    }
    for (final spec in request.model.inputs) {
      if (spec.shape.isNotEmpty &&
          spec.shape.first == -1 &&
          request.tensors[spec.name]!.shape.first != 1) {
        return Future.value(
          rejection(
            MlOutcomeStatus.invalid,
            'A scheduled actor occupies exactly one batch row.',
          ),
        );
      }
    }
    if (_queue.length >= maxQueuedRequests ||
        request.byteLength > maxQueuedBytes - _queuedBytes) {
      return Future.value(
        rejection(
          MlOutcomeStatus.capacity,
          'Request queue count or tensor-byte budget exceeded.',
        ),
      );
    }
    final entry = _Queued(request);
    _queue.add(entry);
    _active[request.id] = entry;
    _queuedBytes += request.byteLength;
    _timer ??= Timer(batchWait, _pump);
    return entry.completion.future;
  }

  bool _expired(MlRequest request) =>
      request.deadlineTick < currentTick() ||
      (request.deadline != null && !DateTime.now().isBefore(request.deadline!));

  void cancel(String requestId) {
    final entry = _active[requestId];
    if (entry == null) return;
    entry.cancelled = true;
    if (!entry.running) {
      _queue.remove(entry);
      _queuedBytes -= entry.request.byteLength;
      _complete(
        entry,
        MlOutcomeStatus.cancelled,
        message: 'Request cancelled before dispatch.',
      );
    }
  }

  void _complete(
    _Queued entry,
    MlOutcomeStatus status, {
    String? message,
    MlTensorMap tensors = const {},
    MlTiming timing = const MlTiming(),
  }) {
    _active.remove(entry.request.id);
    if (!entry.completion.isCompleted) {
      entry.completion.complete(
        MlOutcome(
          status: status,
          request: entry.request,
          completedTick: currentTick(),
          message: message,
          tensors: tensors,
          timing: timing,
        ),
      );
    }
  }

  bool _batchable(MlRequest first, MlRequest candidate) {
    if (first.modelHash != candidate.modelHash ||
        first.model.encode() != candidate.model.encode()) {
      return false;
    }
    if (first.model.inputs.any((s) => s.shape.isEmpty || s.shape.first != -1) ||
        first.model.outputs.any(
          (s) => s.shape.isEmpty || s.shape.first != -1,
        )) {
      return false;
    }
    for (final spec in first.model.inputs) {
      final a = first.tensors[spec.name]!.shape;
      final b = candidate.tensors[spec.name]!.shape;
      for (var i = 1; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
    }
    return true;
  }

  void _pump() {
    _timer?.cancel();
    _timer = null;
    if (_closed) return;
    for (final entry in _queue.toList()) {
      if (entry.isCancelled || _expired(entry.request)) {
        _queue.remove(entry);
        _queuedBytes -= entry.request.byteLength;
        _complete(
          entry,
          entry.isCancelled
              ? MlOutcomeStatus.cancelled
              : MlOutcomeStatus.expired,
        );
      }
    }
    while (_queue.isNotEmpty && _jobs.length < maxInFlightBatches) {
      final first = _queue.first;
      var slotLimit = maxBatchSlots;
      for (final spec in [
        ...first.request.model.inputs,
        ...first.request.model.outputs,
      ]) {
        if (spec.shape.isNotEmpty &&
            spec.shape.first == -1 &&
            spec.maxShape.first < slotLimit) {
          slotLimit = spec.maxShape.first;
        }
      }
      final group = <_Queued>[first];
      for (final candidate in _queue.skip(1)) {
        if (group.length >= slotLimit) break;
        if (_batchable(first.request, candidate.request)) group.add(candidate);
      }
      final payload = group.fold<int>(0, (n, e) => n + e.request.byteLength);
      for (final entry in group) {
        _queue.remove(entry);
        entry.running = true;
      }
      _queuedBytes -= payload;
      _inFlightBytes += payload;
      late final Future<void> job;
      job = _dispatch(group).whenComplete(() {
        _jobs.remove(job);
        _inFlightBytes -= payload;
        if (!_closed) _pump();
      });
      _jobs.add(job);
    }
  }

  Future<void> _dispatch(List<_Queued> group) async {
    MlModelLease? lease;
    final queueTime = group.first.age.elapsed;
    try {
      lease = await cache.acquire(group.first.request.model);
      final admitted = group.where((entry) {
        if (entry.isCancelled || _expired(entry.request)) {
          _complete(
            entry,
            entry.isCancelled
                ? MlOutcomeStatus.cancelled
                : MlOutcomeStatus.expired,
          );
          return false;
        }
        return true;
      }).toList();
      if (admitted.isEmpty) return;
      final cold = cache.isCold(lease);
      final watch = Stopwatch()..start();
      // Each request retains its own deadline; a shorter actor deadline must
      // not cancel other actors in the same shared ORT batch.
      final result = await lease.run(
        _stack(admitted),
        MlRunOptions(requestId: admitted.first.request.id),
      );
      final timing = MlTiming(
        queue: queueTime,
        modelLoad: lease.newlyLoaded ? lease.loadTime : Duration.zero,
        nativeRun: result.elapsed,
        workerRoundTrip: watch.elapsed,
        cold: cold,
      );
      final published = <String, MlOutcome>{};
      final publishedSlots = <int>[];
      for (var slot = 0; slot < admitted.length; slot++) {
        final entry = admitted[slot];
        if (entry.isCancelled || _expired(entry.request)) {
          _complete(
            entry,
            entry.isCancelled
                ? MlOutcomeStatus.cancelled
                : MlOutcomeStatus.expired,
            timing: timing,
          );
          continue;
        }
        final status = MlOutcomeStatus.values.byName(result.status.name);
        final tensors = status == MlOutcomeStatus.ok
            ? _unstack(result.tensors, slot, admitted.length)
            : const <String, MlTensor>{};
        _complete(
          entry,
          status,
          tensors: tensors,
          message: result.message,
          timing: timing,
        );
        published[entry.request.id] = await entry.completion.future;
        publishedSlots.add(slot);
      }
      _batches.add(
        MlBatchReceipt(
          MlBatchMap(published.keys.toList(), publishedSlots),
          published,
        ),
      );
    } catch (e) {
      final status = e is MlCapacityException
          ? MlOutcomeStatus.capacity
          : e is MlLoadException
          ? MlOutcomeStatus.values.byName(e.status.name)
          : MlOutcomeStatus.failed;
      for (final entry in group) {
        if (!entry.completion.isCompleted) {
          _complete(
            entry,
            entry.isCancelled
                ? MlOutcomeStatus.cancelled
                : _expired(entry.request)
                ? MlOutcomeStatus.expired
                : status,
            message: e.toString(),
          );
        }
      }
    } finally {
      if (lease != null) await cache.release(lease);
    }
  }

  MlTensorMap _stack(List<_Queued> entries) {
    if (entries.length == 1) return entries.first.request.tensors;
    final output = <String, MlTensor>{};
    for (final spec in entries.first.request.model.inputs) {
      final bytes = BytesBuilder(copy: false);
      for (final entry in entries) {
        bytes.add(entry.request.tensors[spec.name]!.bytes);
      }
      output[spec.name] = MlTensor(spec.dtype, [
        entries.length,
        ...entries.first.request.tensors[spec.name]!.shape.skip(1),
      ], bytes.takeBytes());
    }
    return output;
  }

  MlTensorMap _unstack(MlTensorMap tensors, int slot, int slots) {
    if (slots == 1) return tensors;
    return tensors.map((name, tensor) {
      if (tensor.shape.isEmpty || tensor.shape.first != slots) {
        throw StateError(
          'Native output batch dimension differs from slot map.',
        );
      }
      final stride = tensor.byteLength ~/ slots;
      return MapEntry(
        name,
        MlTensor(
          tensor.dtype,
          [1, ...tensor.shape.skip(1)],
          Uint8List.sublistView(
            tensor.bytes,
            slot * stride,
            (slot + 1) * stride,
          ),
        ),
      );
    });
  }

  Future<void> flush() async {
    _pump();
    while (_jobs.isNotEmpty) {
      await Future.wait(_jobs.toList());
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _timer?.cancel();
    for (final entry in _active.values.toList()) {
      entry.cancelled = true;
      if (!entry.running) {
        _complete(
          entry,
          MlOutcomeStatus.cancelled,
          message: 'Scheduler closed before dispatch.',
        );
      }
    }
    _queue.clear();
    _queuedBytes = 0;
    await Future.wait(_jobs.toList());
    await cache.close();
    await _batches.close();
  }
}
