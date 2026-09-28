part of 'native_renderer.dart';

final class GraphCacheStats {
  final int liveGraphs,
      descriptionBytes,
      cachedPipelines,
      pipelineCompilations,
      cacheHits;
  const GraphCacheStats({
    required this.liveGraphs,
    required this.descriptionBytes,
    required this.cachedPipelines,
    required this.pipelineCompilations,
    required this.cacheHits,
  });
}

final class _GraphKey {
  final List<int> values;
  _GraphKey(List<int> values) : values = List.unmodifiable(values);
}

Object? _graphEncode(Object? value) => switch (value) {
  _ResourceKey(:final bytes) => [
    for (var i = 0; i < 4; i++)
      ByteData.sublistView(bytes).getUint64(i * 8, Endian.little),
  ],
  _ShaderKey(:final values) => values,
  _GraphKey(:final values) => values,
  Map value => {
    for (final entry in value.entries)
      entry.key as String: _graphEncode(entry.value),
  },
  List value => value.map(_graphEncode).toList(),
  _ => value,
};

mixin _NativeGraphs {
  WorkerSession get _worker;
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
    final reply =
        await _worker.request('graph', [
              TransferableTypedData.fromList([bytes]),
              256 * 1024,
            ])
            as List<Object>;
    if (reply[0] != 0) throw StateError(reply[1] as String);
    final result =
        jsonDecode(
              utf8.decode(
                (reply[1] as TransferableTypedData).materialize().asUint8List(),
              ),
            )
            as Map<String, dynamic>;
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

  Future<Object> compileGraph(GraphDeviceDescription description) async {
    final result = await _graphCommand({
      'operation': 'compile',
      'description': description.data,
    });
    return _GraphKey((result['key'] as List<dynamic>).cast<int>());
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

  Future<GraphCacheStats> graphStats() async {
    final result = await _graphCommand({'operation': 'stats'});
    return GraphCacheStats(
      liveGraphs: result['liveGraphs'] as int,
      descriptionBytes: result['descriptionBytes'] as int,
      cachedPipelines: result['cachedPipelines'] as int,
      pipelineCompilations: result['pipelineCompilations'] as int,
      cacheHits: result['cacheHits'] as int,
    );
  }
}
