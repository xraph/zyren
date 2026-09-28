part of 'native_renderer.dart';

/// Live shader ownership and cache counters on one native device.
/// Source bytes describe admitted source storage, not driver GPU memory.
final class ShaderStats {
  final int residentSourceBytes, livePrograms, cachedModules;
  final int compilationCount, cacheHits;
  const ShaderStats({
    required this.residentSourceBytes,
    required this.livePrograms,
    required this.cachedModules,
    required this.compilationCount,
    required this.cacheHits,
  });
}

final class _ShaderKey {
  final List<int> values;
  _ShaderKey(List<int> values) : values = List.unmodifiable(values);
}

mixin _NativeShaders implements ShaderDevice {
  WorkerSession get _worker;
  int _shaderRequest = 0;

  Future<Map<String, dynamic>> _shaderCommand(
    Map<String, Object> command, {
    ShaderSource? source,
  }) async {
    final request = ++_shaderRequest;
    final bytes = utf8.encode(
      jsonEncode({'version': 1, 'request': request, 'command': command}),
    );
    final reply =
        await _worker.request('shader', [
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
      throw StateError('Invalid native shader response.');
    }
    if (result['error'] case final Map<String, dynamic> error) {
      final code = ShaderErrorCode.values.byName(error['code'] as String);
      final diagnostics = _shaderDiagnostics(
        error['diagnostics'] as List<dynamic>,
      );
      if (source != null) {
        throw ShaderCompilationException(source, diagnostics, code: code);
      }
      throw SceneException(
        SceneIssue(
          code: 'shader.${code.name}',
          message: diagnostics.first.message,
          operation: command['operation'] as String,
        ),
      );
    }
    return result['result'] as Map<String, dynamic>;
  }

  @override
  Future<ShaderBuild> compileShader(ShaderSource source) async {
    final result = await _shaderCommand({
      'operation': 'compile',
      'source': source.code,
      'label': source.label,
    }, source: source);
    return ShaderBuild(
      key: _ShaderKey((result['key'] as List<dynamic>).cast<int>()),
      entryPoints: (result['entryPoints'] as List<dynamic>).map((
        dynamic value,
      ) {
        final entry = value as Map<String, dynamic>;
        final group = entry['workgroupSize'] as List<dynamic>?;
        return ShaderEntryPoint(
          name: entry['name'] as String,
          stage: ShaderStage.values.byName(entry['stage'] as String),
          workgroupSize: group == null
              ? null
              : (group[0] as int, group[1] as int, group[2] as int),
        );
      }),
      diagnostics: _shaderDiagnostics(result['diagnostics'] as List<dynamic>),
    );
  }

  @override
  Future<void> retainShader(Object key) async {
    await _shaderCommand({
      'operation': 'retain',
      'key': (key as _ShaderKey).values,
    });
  }

  @override
  Future<void> releaseShader(Object key) async {
    await _shaderCommand({
      'operation': 'release',
      'key': (key as _ShaderKey).values,
    });
  }

  Future<ShaderStats> shaderStats() async {
    final stats = await _shaderCommand({'operation': 'stats'});
    return ShaderStats(
      residentSourceBytes: stats['residentSourceBytes'] as int,
      livePrograms: stats['livePrograms'] as int,
      cachedModules: stats['cachedModules'] as int,
      compilationCount: stats['compilationCount'] as int,
      cacheHits: stats['cacheHits'] as int,
    );
  }
}

List<ShaderDiagnostic> _shaderDiagnostics(List<dynamic> values) =>
    values.map((dynamic value) {
      final diagnostic = value as Map<String, dynamic>;
      final location = diagnostic['location'] as Map<String, dynamic>?;
      return ShaderDiagnostic(
        message: diagnostic['message'] as String,
        severity: ShaderDiagnosticSeverity.values.byName(
          diagnostic['severity'] as String,
        ),
        location: location == null
            ? null
            : ShaderLocation(
                line: location['line'] as int,
                column: location['column'] as int,
                offset: location['offset'] as int,
                length: location['length'] as int,
              ),
      );
    }).toList();
