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

/// A suballocation known to the native wgpu allocator. Names may be truncated.
/// Offsets are relative to their allocator memory blocks, not global addresses.
final class GpuAllocatorAllocation {
  final String name;
  final int offset, size;
  const GpuAllocatorAllocation({
    required this.name,
    required this.offset,
    required this.size,
  });
  Map<String, Object?> toJson() => {
    'name': name,
    'offset': offset,
    'size': size,
  };
}

/// One native memory query, scoped to a device, heap or adapter segment.
/// Usage and budget are independent snapshots and never physical residency.
final class GpuMemoryReport {
  /// `available`, `unsupported` or `error`. Unknown measurements remain null.
  final String status, source, scope, region;
  final int? heapIndex, nodeIndex;
  final bool? deviceLocal, unifiedMemory;
  final int? usageBytes, budgetBytes;

  /// Metal's approximate performance guidance, separate from an OS budget.
  /// Null on older OS versions that do not expose the recommendation.
  final int? recommendedMaxWorkingSetBytes;
  final bool usageIsEstimate, budgetIsEstimate;
  final String? reason;
  const GpuMemoryReport({
    required this.status,
    required this.source,
    required this.scope,
    required this.region,
    this.heapIndex,
    this.nodeIndex,
    this.deviceLocal,
    this.unifiedMemory,
    this.usageBytes,
    this.budgetBytes,
    this.recommendedMaxWorkingSetBytes,
    this.usageIsEstimate = false,
    this.budgetIsEstimate = false,
    this.reason,
  });

  factory GpuMemoryReport.fromJson(Map<String, Object?> json) =>
      GpuMemoryReport(
        status: json['status'] as String,
        source: json['source'] as String,
        scope: json['scope'] as String,
        region: json['region'] as String,
        heapIndex: json['heapIndex'] as int?,
        nodeIndex: json['nodeIndex'] as int?,
        deviceLocal: json['deviceLocal'] as bool?,
        unifiedMemory: json['unifiedMemory'] as bool?,
        usageBytes: json['usageBytes'] as int?,
        budgetBytes: json['budgetBytes'] as int?,
        recommendedMaxWorkingSetBytes:
            json['recommendedMaxWorkingSetBytes'] as int?,
        usageIsEstimate: json['usageIsEstimate'] as bool? ?? false,
        budgetIsEstimate: json['budgetIsEstimate'] as bool? ?? false,
        reason: json['reason'] as String?,
      );

  Map<String, Object?> toJson() => {
    'status': status,
    'source': source,
    'scope': scope,
    'region': region,
    'heapIndex': heapIndex,
    'nodeIndex': nodeIndex,
    'deviceLocal': deviceLocal,
    'unifiedMemory': unifiedMemory,
    'usageBytes': usageBytes,
    'budgetBytes': budgetBytes,
    'recommendedMaxWorkingSetBytes': recommendedMaxWorkingSetBytes,
    'usageIsEstimate': usageIsEstimate,
    'budgetIsEstimate': budgetIsEstimate,
    'reason': reason,
  };
}

final class GpuInspection {
  /// On-demand backend reports. Regions can overlap with allocator/device
  /// counters; do not add them together. Empty when an older runtime omits them.
  final List<GpuMemoryReport> memoryReports;

  /// wgpu suballocator used and reserved bytes. Excludes imported resources,
  /// driver overhead and allocations outside this device's suballocator.
  final int? allocatorUsedBytes,
      allocatorReservedBytes,
      allocatorAllocationCount;
  final String allocatorSource;
  final List<GpuAllocatorAllocation> allocatorAllocations;

  /// Cumulative diagnostic timestamp readbacks, separate from scene pixel copies.
  final int diagnosticReadbackBytes;

  /// Last completed scene submission, in nanoseconds, from [gpuTimeSource].
  /// Includes recorded GPU copies and gaps between passes. CPU encoding and
  /// reading mapped pixels are excluded. Unsupported measurements stay null.
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
    Iterable<GpuMemoryReport> memoryReports = const [],
    this.allocatorUsedBytes,
    this.allocatorReservedBytes,
    this.allocatorAllocationCount,
    this.allocatorSource = 'unavailable',
    Iterable<GpuAllocatorAllocation> allocatorAllocations = const [],
    this.diagnosticReadbackBytes = 0,
    this.lastSubmissionGpuTimeNs,
    this.submittedFrames = 0,
    this.gpuTimeSource = 'unavailable',
    this.deviceAllocatedBytes,
    this.residentBytes,
    required this.deviceAllocationSource,
    required this.registryPayloadBytes,
    required this.totalAllocations,
    required Iterable<GpuAllocationInfo> allocations,
  }) : memoryReports = List.unmodifiable(memoryReports),
       allocations = List.unmodifiable(allocations),
       allocatorAllocations = List.unmodifiable(allocatorAllocations);
  bool get truncated => allocations.length < totalAllocations;
  Map<String, Object?> toJson() => {
    'memoryReports': memoryReports.map((report) => report.toJson()).toList(),
    'allocatorUsedBytes': allocatorUsedBytes,
    'allocatorReservedBytes': allocatorReservedBytes,
    'allocatorAllocationCount': allocatorAllocationCount,
    'allocatorSource': allocatorSource,
    'allocatorAllocations': allocatorAllocations
        .map((a) => a.toJson())
        .toList(),
    'allocatorTruncated': allocatorAllocationCount == null
        ? null
        : allocatorAllocations.length < allocatorAllocationCount!,
    'diagnosticReadbackBytes': diagnosticReadbackBytes,
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
