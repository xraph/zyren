import 'dart:async';
import 'package:zyren/zyren.dart';
import 'policy.dart';
import 'store.dart';

final class GeoRequestPoolStats {
  final int active, queued, consumers, reservedBytes;
  const GeoRequestPoolStats(
    this.active,
    this.queued,
    this.consumers,
    this.reservedBytes,
  );
}

/// Coalesces compatible requests and holds admission while cancelled work drains.
final class GeoRequestPool {
  final int maxConcurrent,
      maxPerSource,
      maxQueued,
      maxInFlightBytes,
      maxConsumers;
  final _byKey = <Object, _Job>{};
  final _all = <_Job>{}, _waiting = <_Job>[];
  final _bySource = <String, int>{};
  final _closedFuture = Completer<void>();
  int _active = 0, _reserved = 0;
  bool _closed = false;
  GeoRequestPool({
    this.maxConcurrent = 8,
    this.maxPerSource = 4,
    this.maxQueued = 128,
    this.maxConsumers = 1024,
    this.maxInFlightBytes = 64 * 1024 * 1024,
  }) {
    if (maxConcurrent < 1 ||
        maxConcurrent > 1024 ||
        maxPerSource < 1 ||
        maxQueued < 1 ||
        maxQueued > 100000 ||
        maxConsumers < 1 ||
        maxConsumers > 100000 ||
        maxInFlightBytes < 1) {
      throw ArgumentError('Request admission needs bounded positive limits.');
    }
  }
  GeoRequestPoolStats get stats => GeoRequestPoolStats(
    _active,
    _waiting.length,
    _all.fold(0, (sum, job) => sum + job.consumers.length),
    _reserved,
  );
  Future<GeoResource> run(
    Object key,
    String sourceId, {
    required Future<GeoResource> Function(LoadCancellation) work,
    required LoadCancellation cancellation,
    required int reservationBytes,
  }) {
    if (_closed) {
      return Future.error(const GeoDataException(GeoDataError.closed));
    }
    if (cancellation.isCancelled) {
      return Future.error(const GeoDataException(GeoDataError.cancelled));
    }
    if (reservationBytes < 1 || reservationBytes > maxInFlightBytes) {
      return Future.error(const GeoDataException(GeoDataError.budgetExceeded));
    }
    if (sourceId.isEmpty || sourceId.length > 1024) {
      return Future.error(ArgumentError('Invalid request source ID.'));
    }
    if (stats.consumers >= maxConsumers) {
      return Future.error(const GeoDataException(GeoDataError.budgetExceeded));
    }
    var job = _byKey[key];
    if (job != null &&
        (job.source != sourceId || job.bytes != reservationBytes)) {
      return Future.error(
        ArgumentError('Coalesced reads require matching source and admission.'),
      );
    }
    if (job == null) {
      if (_waiting.length >= maxQueued) {
        return Future.error(
          const GeoDataException(GeoDataError.budgetExceeded),
        );
      }
      job = _Job(key, sourceId, reservationBytes, work);
      _byKey[key] = job;
      _all.add(job);
      _waiting.add(job);
    }
    final accepted = job;
    final consumer = _Consumer();
    // Consumers can attach error handling after cancellation without a zone leak.
    consumer.result.future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    accepted.consumers.add(consumer);
    consumer.registration = cancellation.onCancel(() {
      _cancelConsumer(accepted, consumer, GeoDataError.cancelled);
    });
    if (consumer.result.isCompleted) consumer.registration!.dispose();
    _pump();
    return consumer.result.future;
  }

  void _cancelConsumer(_Job job, _Consumer consumer, GeoDataError reason) {
    if (!job.consumers.remove(consumer)) return;
    consumer.registration?.dispose();
    consumer.result.completeError(GeoDataException(reason));
    if (job.consumers.isEmpty) {
      if (identical(_byKey[job.key], job)) _byKey.remove(job.key);
      job.cancellation.cancel();
      if (!job.running) {
        _waiting.remove(job);
        _all.remove(job);
      }
    }
    _pump();
    _finishClose();
  }

  void cancelWhere(bool Function(Object key, String sourceId) matches) {
    for (final job in _all.toList()) {
      if (!matches(job.key, job.source)) continue;
      for (final consumer in job.consumers.toList()) {
        _cancelConsumer(job, consumer, GeoDataError.cancelled);
      }
    }
  }

  void _pump() {
    if (_closed) return;
    while (_active < maxConcurrent) {
      final index = _waiting.indexWhere(
        (job) =>
            (_bySource[job.source] ?? 0) < maxPerSource &&
            _reserved + job.bytes <= maxInFlightBytes,
      );
      if (index < 0) break;
      final job = _waiting.removeAt(index);
      job.running = true;
      _active++;
      _reserved += job.bytes;
      _bySource[job.source] = (_bySource[job.source] ?? 0) + 1;
      unawaited(_run(job));
    }
  }

  Future<void> _run(_Job job) async {
    try {
      final result = await job.work(job.cancellation);
      for (final consumer in job.consumers.toList()) {
        consumer.registration?.dispose();
        consumer.result.complete(result);
      }
    } catch (error, stack) {
      for (final consumer in job.consumers.toList()) {
        consumer.registration?.dispose();
        consumer.result.completeError(error, stack);
      }
    } finally {
      job.consumers.clear();
      job.cancellation.finish();
      if (identical(_byKey[job.key], job)) _byKey.remove(job.key);
      _all.remove(job);
      _active--;
      _reserved -= job.bytes;
      final remaining = _bySource[job.source]! - 1;
      if (remaining == 0) {
        _bySource.remove(job.source);
      } else {
        _bySource[job.source] = remaining;
      }
      _pump();
      _finishClose();
    }
  }

  Future<void> close() {
    if (!_closed) {
      _closed = true;
      for (final job in _all.toList()) {
        for (final consumer in job.consumers.toList()) {
          _cancelConsumer(job, consumer, GeoDataError.closed);
        }
      }
      _finishClose();
    }
    return _closedFuture.future;
  }

  void _finishClose() {
    if (_closed && _all.isEmpty && !_closedFuture.isCompleted) {
      _closedFuture.complete();
    }
  }
}

final class _Consumer {
  final result = Completer<GeoResource>();
  Registration? registration;
}

final class _Job {
  final Object key;
  final String source;
  final int bytes;
  final Future<GeoResource> Function(LoadCancellation) work;
  final cancellation = LoadCancellationSource();
  final consumers = <_Consumer>{};
  bool running = false;
  _Job(this.key, this.source, this.bytes, this.work);
}
