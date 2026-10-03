part of 'native_renderer.dart';

final class NativeDeviceInfo {
  final String backend, adapterName;
  final Set<int> sampleCounts;
  NativeDeviceInfo._(Map value)
    : backend = value['backend'] as String,
      adapterName = value['adapterName'] as String,
      sampleCounts = Set.unmodifiable(
        (value['sampleCounts'] as List).cast<int>(),
      );
}

final class _MaterialKey {
  final List<int> values;
  _MaterialKey(List<int> values) : values = List.unmodifiable(values);
}

/// Internal depth atlases, separate from application-owned resource scopes.
final class ShadowStats {
  final int atlasCount, residentBytes, renderedViews, reusedFrames;
  const ShadowStats({
    required this.atlasCount,
    required this.residentBytes,
    required this.renderedViews,
    required this.reusedFrames,
  });
}

/// Shared opaque capture payload and fixed fallback bindings.
/// Separate from application resource scopes, shadows and temporal history.
final class TransmissionStats {
  final int residentBytes, fixedBytes;
  const TransmissionStats({
    required this.residentBytes,
    required this.fixedBytes,
  });
}

/// Device-wide temporal attachments and retained motion buffers.
/// Separate from application resource scopes and shadow atlases.
final class TemporalStats {
  final int residentBytes, historyViews;
  const TemporalStats({
    required this.residentBytes,
    required this.historyViews,
  });
}

final class GraphCacheStats {
  final int shadowBytes, shadowPasses;
  final int instanceBytes, instanceUploadedBytes, instanceDrawCalls;
  final int liveMaterials, targetBytes;
  final int liveGraphs,
      descriptionBytes,
      cachedPipelines,
      pipelineCompilations,
      cacheHits,
      liveMeshShaders,
      meshPipelines;
  const GraphCacheStats({
    this.shadowBytes = 0,
    this.instanceBytes = 0,
    this.instanceUploadedBytes = 0,
    this.instanceDrawCalls = 0,
    this.shadowPasses = 0,
    this.liveMaterials = 0,
    this.targetBytes = 0,
    required this.liveGraphs,
    required this.descriptionBytes,
    required this.cachedPipelines,
    required this.pipelineCompilations,
    required this.cacheHits,
    this.liveMeshShaders = 0,
    this.meshPipelines = 0,
  });
}

final class _GraphKey {
  final List<int> values;
  _GraphKey(List<int> values) : values = List.unmodifiable(values);
}

final class _MeshShaderKey {
  final List<int> values;
  _MeshShaderKey(List<int> values) : values = List.unmodifiable(values);
}

Object? _graphEncode(Object? value) => switch (value) {
  _ResourceKey(:final bytes) => [
    for (var i = 0; i < 4; i++)
      ByteData.sublistView(bytes).getUint64(i * 8, Endian.little),
  ],
  _ShaderKey(:final values) => values,
  _GraphKey(:final values) => values,
  _MaterialKey(:final values) => values,
  _MeshShaderKey(:final values) => values,
  Map value => {
    for (final entry in value.entries)
      entry.key as String: _graphEncode(entry.value),
  },
  List value => value.map(_graphEncode).toList(),
  _ => value,
};

mixin _NativeGraphs {
  Future<NativeGpuReply> _submit(
    NativeGpuCommand kind,
    Uint8List bytes,
    int capacity,
  );
  int _graphRequest = 0;
  Future<Map<String, dynamic>> _graphCommand(
    Map<String, Object?> command,
  ) async {
    final request = ++_graphRequest;
    final bytes = utf8.encode(
      jsonEncode({
        'version': 1,
        'request': request,
        'command': _graphEncode(command),
      }),
    );
    final reply = await _submit(NativeGpuCommand.graph, bytes, 256 * 1024);
    if (reply.status != 0) throw StateError(reply.message!);
    final result =
        jsonDecode(utf8.decode(reply.bytes!)) as Map<String, dynamic>;
    if (result['version'] != 1 || result['request'] != request) {
      throw StateError('Invalid native graph response.');
    }
    if (result['error'] case final Map<String, dynamic> error) {
      throw GraphException(
        GraphErrorCode.values.byName(error['code'] as String),
        error['message'] as String,
        passName: error['passName'] as String?,
        resourceLabel: error['resourceLabel'] as String?,
      );
    }
    return result['result'] as Map<String, dynamic>;
  }

  Future<Object> compileMeshShader(
    MeshShaderDeviceDescription description,
  ) async {
    final result = await _graphCommand({
      'operation': 'compileMesh',
      'description': description.data,
    });
    return _MeshShaderKey((result['key'] as List<dynamic>).cast<int>());
  }

  Future<void> releaseMeshShader(Object key) async {
    await _graphCommand({
      'operation': 'releaseMesh',
      'key': key as _MeshShaderKey,
    });
  }

  Future<Object> compileGraph(GraphDeviceDescription description) async {
    final result = await _graphCommand({
      'operation': 'compile',
      'description': description.data,
    });
    return _GraphKey((result['key'] as List<dynamic>).cast<int>());
  }

  Future<Object> compileMaterial(GraphDeviceDescription description) async {
    final result = await _graphCommand({
      'operation': 'compileMaterial',
      'description': description.data,
    });
    return _MaterialKey((result['key'] as List<dynamic>).cast<int>());
  }

  Future<void> releaseMaterial(Object key) async {
    await _graphCommand({
      'operation': 'releaseMaterial',
      'key': key as _MaterialKey,
    });
  }

  Future<void> retainMaterial(Object key) async {
    await _graphCommand({
      'operation': 'retainMaterial',
      'key': key as _MaterialKey,
    });
  }

  Uint8List encodeMaterialKey(Object key) {
    final bytes = _ResourcePacket();
    for (final value in (key as _MaterialKey).values) {
      bytes.u64(value);
    }
    return bytes.finish();
  }

  Future<GraphStats> executeGraph(Object key) async {
    final result = await _graphCommand({
      'operation': 'execute',
      'key': key as _GraphKey,
    });
    return GraphStats(
      passes: result['passes'] as int,
      dispatches: result['dispatches'] as int,
      drawCalls: result['drawCalls'] as int,
    );
  }

  Future<void> releaseGraph(Object key) async {
    await _graphCommand({'operation': 'release', 'key': key as _GraphKey});
  }

  Future<NativeFrameProfile> frameProfile() async =>
      NativeFrameProfile.fromJson(
        (await _graphCommand({
          'operation': 'frameProfile',
        })).cast<String, Object?>(),
      );

  Future<GpuInspection> inspectGpu({int allocationLimit = 128}) async {
    if (allocationLimit < 1 || allocationLimit > 256) {
      throw RangeError.range(allocationLimit, 1, 256, 'allocationLimit');
    }
    final result = await _graphCommand({
      'operation': 'inspectGpu',
      'allocation_limit': allocationLimit,
    });
    return GpuInspection(
      memoryReports: ((result['memoryReports'] as List?) ?? []).map(
        (value) =>
            GpuMemoryReport.fromJson((value as Map).cast<String, Object?>()),
      ),
      allocatorUsedBytes: result['allocatorUsedBytes'] as int?,
      allocatorReservedBytes: result['allocatorReservedBytes'] as int?,
      allocatorAllocationCount: result['allocatorAllocationCount'] as int?,
      allocatorSource: result['allocatorSource'] as String? ?? 'unavailable',
      diagnosticReadbackBytes: result['diagnosticReadbackBytes'] as int? ?? 0,
      allocatorAllocations: ((result['allocatorAllocations'] as List?) ?? [])
          .map(
            (value) => GpuAllocatorAllocation(
              name: value['name'] as String,
              offset: value['offset'] as int,
              size: value['size'] as int,
            ),
          ),
      frameProfile: result['frameProfile'] == null
          ? null
          : NativeFrameProfile.fromJson(
              (result['frameProfile'] as Map).cast<String, Object?>(),
            ),
      lastSubmissionGpuTimeNs: result['lastSubmissionGpuTimeNs'] as int?,
      submittedFrames: result['submittedFrames'] as int,
      gpuTimeSource: result['gpuTimeSource'] as String,
      deviceAllocatedBytes: result['deviceAllocatedBytes'] as int?,
      deviceAllocationSource: result['deviceAllocationSource'] as String,
      registryPayloadBytes: result['registryPayloadBytes'] as int,
      totalAllocations: result['totalAllocations'] as int,
      allocations: (result['allocations'] as List).map(
        (value) => GpuAllocationInfo(
          id: value['id'] as String,
          kind: value['kind'] as String,
          payloadBytes: value['payloadBytes'] as int,
          references: value['references'] as int,
          lastSubmission: value['lastSubmission'] as int,
        ),
      ),
    );
  }

  Future<TransmissionStats> transmissionStats() async {
    final result = await _graphCommand({'operation': 'transmissionStats'});
    return TransmissionStats(
      residentBytes: result['residentBytes'] as int,
      fixedBytes: result['fixedBytes'] as int,
    );
  }

  Future<TemporalStats> temporalStats() async {
    final result = await _graphCommand({'operation': 'temporalStats'});
    return TemporalStats(
      residentBytes: result['residentBytes'] as int,
      historyViews: result['historyViews'] as int,
    );
  }

  Future<ShadowStats> shadowStats() async {
    final result = await _graphCommand({'operation': 'shadowStats'});
    return ShadowStats(
      atlasCount: result['atlasCount'] as int,
      residentBytes: result['residentBytes'] as int,
      renderedViews: result['renderedViews'] as int,
      reusedFrames: result['reusedFrames'] as int,
    );
  }

  Future<NativeDeviceInfo> deviceInfo() async =>
      NativeDeviceInfo._(await _graphCommand({'operation': 'deviceInfo'}));

  Future<GraphCacheStats> graphStats() async {
    final result = await _graphCommand({'operation': 'stats'});
    return GraphCacheStats(
      shadowBytes: result['shadowBytes'] as int,
      instanceBytes: result['instanceBytes'] as int,
      instanceUploadedBytes: result['instanceUploadedBytes'] as int,
      instanceDrawCalls: result['instanceDrawCalls'] as int,
      shadowPasses: result['shadowPasses'] as int,
      liveMaterials: result['liveMaterials'] as int,
      targetBytes: result['targetBytes'] as int,
      liveGraphs: result['liveGraphs'] as int,
      descriptionBytes: result['descriptionBytes'] as int,
      cachedPipelines: result['cachedPipelines'] as int,
      pipelineCompilations: result['pipelineCompilations'] as int,
      cacheHits: result['cacheHits'] as int,
      liveMeshShaders: result['liveMeshShaders'] as int,
      meshPipelines: result['meshPipelines'] as int,
    );
  }
}
