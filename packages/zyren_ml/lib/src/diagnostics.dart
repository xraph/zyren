/// Admission counters are separate from native allocator and process memory.
final class MlDiagnostics {
  const MlDiagnostics({
    this.queuedRequests = 0,
    this.queuedTensorBytes = 0,
    this.inFlightBatches = 0,
    this.inFlightTensorBytes = 0,
    this.residentModels = 0,
    this.modelWeightsBytes = 0,
    this.leaseReferences = 0,
    this.inFlightReferences = 0,
    this.nativeArenaBytes,
    this.recurrentStateBytes,
    this.sensorBytes,
  });
  final int queuedRequests;
  final int queuedTensorBytes;
  final int inFlightBatches;
  final int inFlightTensorBytes;
  final int residentModels;
  final int modelWeightsBytes;
  final int leaseReferences;
  final int inFlightReferences;
  final int? nativeArenaBytes;
  final int? recurrentStateBytes;
  final int? sensorBytes;
}

final class MlWorkerDiagnostics {
  const MlWorkerDiagnostics({
    required this.residentModels,
    required this.liveSessions,
    required this.liveResults,
    this.completedRuns = 0,
    this.ownerIsolateId,
    this.failureReason,
  });
  final int? residentModels;
  final int? liveSessions;
  final int? liveResults;
  final int? completedRuns;
  final String? ownerIsolateId;
  final String? failureReason;
}

final class MlTiming {
  const MlTiming({
    this.queue = Duration.zero,
    this.modelLoad = Duration.zero,
    this.nativeRun = Duration.zero,
    this.workerRoundTrip = Duration.zero,
    this.cold = false,
  });
  final Duration queue;
  final Duration modelLoad;
  final Duration nativeRun;
  final Duration workerRoundTrip;
  final bool cold;
}
