/// Read-only measurements from one native renderer device.
abstract interface class GpuDiagnosticsBackend {
  Future<GpuInspection> inspectGpu({int allocationLimit = 128});
}

/// Registry payload accounting, separate from physical GPU residency.
final class GpuAllocationInfo {
  final String id, kind;
  final int payloadBytes, references, lastSubmission;
  const GpuAllocationInfo({
    required this.id,
    required this.kind,
    required this.payloadBytes,
    required this.references,
    required this.lastSubmission,
  });
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'payloadBytes': payloadBytes,
    'references': references,
    'lastSubmission': lastSubmission,
  };
}

final class GpuInspection {
  /// Last completed scene submission, in nanoseconds. Includes GPU buffer gaps,
  /// excludes CPU encoding, queue wait, uploads and CPU pixel readback.
  final int? lastSubmissionGpuTimeNs;
  final int submittedFrames;
  final String gpuTimeSource;

  /// Metal device currentAllocatedSize in this process, including other
  /// renderers and views sharing that Metal device.
  /// Excludes allocations on other devices. This is not physical residency.
  final int? deviceAllocatedBytes;

  /// Physical residency is unavailable until a backend can measure it.
  final int? residentBytes;
  final String deviceAllocationSource;

  /// Registry payload sizes include resources awaiting submission retirement.
  /// Excludes frame targets, pipeline objects and temporary staging allocations.
  final int registryPayloadBytes, totalAllocations;
  final List<GpuAllocationInfo> allocations;
  GpuInspection({
    this.lastSubmissionGpuTimeNs,
    this.submittedFrames = 0,
    this.gpuTimeSource = 'unavailable',
    this.deviceAllocatedBytes,
    this.residentBytes,
    required this.deviceAllocationSource,
    required this.registryPayloadBytes,
    required this.totalAllocations,
    required Iterable<GpuAllocationInfo> allocations,
  }) : allocations = List.unmodifiable(allocations);
  bool get truncated => allocations.length < totalAllocations;
  Map<String, Object?> toJson() => {
    'lastSubmissionGpuTimeNs': lastSubmissionGpuTimeNs,
    'submittedFrames': submittedFrames,
    'gpuTimeSource': gpuTimeSource,
    'deviceAllocatedBytes': deviceAllocatedBytes,
    'deviceAllocationSource': deviceAllocationSource,
    'residentBytes': residentBytes,
    'registryPayloadBytes': registryPayloadBytes,
    'totalAllocations': totalAllocations,
    'truncated': truncated,
    'allocations': allocations.map((a) => a.toJson()).toList(),
  };
}
