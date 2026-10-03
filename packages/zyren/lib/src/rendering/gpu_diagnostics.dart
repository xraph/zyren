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
  final NativeFrameProfile? frameProfile;

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
    this.frameProfile,
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
    'frameProfile': frameProfile?.toJson(),
    'deviceAllocatedBytes': deviceAllocatedBytes,
    'deviceAllocationSource': deviceAllocationSource,
    'residentBytes': residentBytes,
    'registryPayloadBytes': registryPayloadBytes,
    'totalAllocations': totalAllocations,
    'truncated': truncated,
    'allocations': allocations.map((a) => a.toJson()).toList(),
  };
}

/// Native scene work from one completed frame. Nanoseconds preserve sub-microsecond
/// samples. Preparation and encoding are CPU intervals; completion wait can overlap
/// GPU execution. Named pass intervals are contained in gpuTimeNs. Do not add them.
/// Resource counters are device-lifetime observations, independent of scene work.
final class NativeFrameProfile {
  final String status, gpuTimeSource;
  final int? drawPlanReuses,
      executedMeshDraws,
      opaqueBatchDraws,
      batchedSourceDraws,
      pipelineSwitches,
      bindGroupSwitches,
      automaticInstanceUploadBytes;
  final int? uploadBacklogBytes, stagedBytes;
  final int? drawUniformReuses,
      drawUniformWriteCalls,
      drawUniformWriteBytes,
      drawUniformSkippedWrites,
      drawCacheEntries,
      drawCacheUniformBytes;
  final bool? candidateReady;
  final int? cpuPrepareNs,
      cpuEncodeNs,
      cpuCompletionWaitNs,
      cpuReadbackNs,
      gpuTimeNs,
      drawCacheReuses;
  final int submissionCount,
      drawPreparationBuffers,
      drawPreparationBindGroups,
      uploadBytes;
  final Map<String, NativePassTiming> passes;
  final Map<String, Object?> resources;
  NativeFrameProfile.fromJson(Map<String, Object?> json)
    : drawPlanReuses = json['drawPlanReuses'] as int?,
      executedMeshDraws = json['executedMeshDraws'] as int?,
      opaqueBatchDraws = json['opaqueBatchDraws'] as int?,
      batchedSourceDraws = json['batchedSourceDraws'] as int?,
      pipelineSwitches = json['pipelineSwitches'] as int?,
      bindGroupSwitches = json['bindGroupSwitches'] as int?,
      automaticInstanceUploadBytes =
          json['automaticInstanceUploadBytes'] as int?,
      drawUniformReuses = json['drawUniformReuses'] as int?,
      drawUniformWriteCalls = json['drawUniformWriteCalls'] as int?,
      drawUniformWriteBytes = json['drawUniformWriteBytes'] as int?,
      drawUniformSkippedWrites = json['drawUniformSkippedWrites'] as int?,
      drawCacheEntries = json['drawCacheEntries'] as int?,
      drawCacheUniformBytes = json['drawCacheUniformBytes'] as int?,
      uploadBacklogBytes = json['uploadBacklogBytes'] as int?,
      stagedBytes = json['stagedBytes'] as int?,
      candidateReady = json['candidateReady'] as bool?,
      status = json['status'] as String,
      cpuPrepareNs = json['cpuPrepareNs'] as int?,
      cpuEncodeNs = json['cpuEncodeNs'] as int?,
      cpuCompletionWaitNs = json['cpuCompletionWaitNs'] as int?,
      cpuReadbackNs = json['cpuReadbackNs'] as int?,
      gpuTimeNs = json['gpuTimeNs'] as int?,
      gpuTimeSource = json['gpuTimeSource'] as String,
      submissionCount = json['submissionCount'] as int,
      drawPreparationBuffers = json['drawPreparationBuffers'] as int,
      drawPreparationBindGroups = json['drawPreparationBindGroups'] as int,
      drawCacheReuses = json['drawCacheReuses'] as int?,
      uploadBytes = json['uploadBytes'] as int,
      passes = Map.unmodifiable(
        (json['passes'] as Map).map(
          (key, value) => MapEntry(
            key as String,
            NativePassTiming.fromJson((value as Map).cast<String, Object?>()),
          ),
        ),
      ),
      resources = Map.unmodifiable(
        (json['resources'] as Map? ?? {}).cast<String, Object?>(),
      );

  /// Actual scene, transmission and outline work, including the outline composite.
  /// Older native runtimes keep the caller's packet estimate.
  int sceneDrawCalls(int fallback) =>
      status == 'complete' && executedMeshDraws != null
      ? executedMeshDraws! + (passes['outlines']?.executed == true ? 1 : 0)
      : fallback;

  /// Additional output draw when a retained graph uses its original size.
  int get resizeCompositeDraws =>
      passes['resizeComposite']?.executed == true ? 1 : 0;

  Duration? get gpuTime =>
      gpuTimeNs == null ? null : Duration(microseconds: gpuTimeNs! ~/ 1000);
  Map<String, Object?> toJson() => {
    if (drawPlanReuses != null) 'drawPlanReuses': drawPlanReuses,
    if (executedMeshDraws != null) 'executedMeshDraws': executedMeshDraws,
    if (opaqueBatchDraws != null) 'opaqueBatchDraws': opaqueBatchDraws,
    if (batchedSourceDraws != null) 'batchedSourceDraws': batchedSourceDraws,
    if (pipelineSwitches != null) 'pipelineSwitches': pipelineSwitches,
    if (bindGroupSwitches != null) 'bindGroupSwitches': bindGroupSwitches,
    if (automaticInstanceUploadBytes != null)
      'automaticInstanceUploadBytes': automaticInstanceUploadBytes,

    if (drawUniformReuses != null) 'drawUniformReuses': drawUniformReuses,
    if (drawUniformWriteCalls != null)
      'drawUniformWriteCalls': drawUniformWriteCalls,
    if (drawUniformWriteBytes != null)
      'drawUniformWriteBytes': drawUniformWriteBytes,
    if (drawUniformSkippedWrites != null)
      'drawUniformSkippedWrites': drawUniformSkippedWrites,
    if (drawCacheEntries != null) 'drawCacheEntries': drawCacheEntries,
    if (drawCacheUniformBytes != null)
      'drawCacheUniformBytes': drawCacheUniformBytes,
    if (uploadBacklogBytes != null) 'uploadBacklogBytes': uploadBacklogBytes,
    if (stagedBytes != null) 'stagedBytes': stagedBytes,
    if (candidateReady != null) 'candidateReady': candidateReady,
    'status': status,
    'cpuPrepareNs': cpuPrepareNs,
    'cpuEncodeNs': cpuEncodeNs,
    'cpuCompletionWaitNs': cpuCompletionWaitNs,
    if (cpuReadbackNs != null) 'cpuReadbackNs': cpuReadbackNs,
    'gpuTimeNs': gpuTimeNs,
    'gpuTimeSource': gpuTimeSource,
    'submissionCount': submissionCount,
    'drawPreparationBuffers': drawPreparationBuffers,
    'drawPreparationBindGroups': drawPreparationBindGroups,
    'drawCacheReuses': drawCacheReuses,
    'uploadBytes': uploadBytes,
    'passes': passes.map((key, value) => MapEntry(key, value.toJson())),
    'resources': resources,
  };
}

/// An absent pass has executed=false. An unmeasured executed pass stays null.
final class NativePassTiming {
  final bool executed;
  final int? drawCalls;
  final int? gpuTimeNs;
  NativePassTiming.fromJson(Map<String, Object?> json)
    : drawCalls = json['drawCalls'] as int?,
      executed = json['executed'] as bool,
      gpuTimeNs = json['gpuTimeNs'] as int?;
  Map<String, Object?> toJson() => {
    if (drawCalls != null) 'drawCalls': drawCalls,
    'executed': executed,
    'gpuTimeNs': gpuTimeNs,
  };
}
