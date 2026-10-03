import 'dart:async';
import 'dart:convert';
import 'dart:io';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> arguments) async {
  final example = File.fromUri(Platform.script).parent.parent;
  final root = example.parent.parent;
  final connection = Completer<Map<String, dynamic>>();
  final ready = Completer<Map<String, dynamic>>();
  final flutter =
      await Process.start(arguments.isEmpty ? 'fvm' : arguments.single, [
        if (arguments.isEmpty) 'flutter',
        'test',
        '--no-pub',
        '-d',
        'macos',
        '--dart-define=STUDIO_NATIVE_MCP=true',
        'integration_test/studio_test.dart',
      ], workingDirectory: example.path);
  final subscriptions = <StreamSubscription<String>>[];
  void readLine(String line) {
    const connectionMarker = 'ZYREN_STUDIO_AGENTS ';
    const readyMarker = 'ZYREN_STUDIO_NATIVE_READY ';
    final connectionIndex = line.indexOf(connectionMarker);
    if (connectionIndex >= 0) {
      if (!connection.isCompleted) {
        connection.complete(
          jsonDecode(line.substring(connectionIndex + connectionMarker.length))
              as Map<String, dynamic>,
        );
      }
      stdout.writeln('Studio native bridge started (credentials redacted).');
      return;
    }
    final readyIndex = line.indexOf(readyMarker);
    if (readyIndex >= 0 && !ready.isCompleted) {
      ready.complete(
        jsonDecode(line.substring(readyIndex + readyMarker.length))
            as Map<String, dynamic>,
      );
      return;
    }
    stdout.writeln(line);
  }

  for (final stream in [flutter.stdout, flutter.stderr]) {
    subscriptions.add(
      stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(readLine),
    );
  }
  final exited = flutter.exitCode;
  unawaited(
    exited.then((code) {
      final error = StateError(
        'Native test exited before MCP readiness ($code).',
      );
      if (!connection.isCompleted) connection.completeError(error);
      if (!ready.isCompleted) ready.completeError(error);
    }),
  );
  try {
    final verification = () async {
      final values = await Future.wait([connection.future, ready.future]);
      final client = await McpClient.start(root, values[0]);
      try {
        await verify(client, values[1]['point'] as Map);
      } finally {
        await client.close();
      }
      await File(values[1]['completionPath'] as String).writeAsString('ok');
    }();
    await Future.wait<void>([
      verification,
      exited.then((code) => require(code == 0, 'Native test failed ($code).')),
    ], eagerError: true).timeout(const Duration(minutes: 5));
    stdout.writeln('Native Studio MCP, editor and lifecycle checks passed.');
  } finally {
    flutter.kill(ProcessSignal.sigint);
    try {
      await exited.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      flutter.kill(ProcessSignal.sigkill);
    }
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}

Future<void> verify(McpClient client, Map point) async {
  await client.request('initialize', {
    'protocolVersion': '2025-11-25',
    'capabilities': <String, Object?>{},
    'clientInfo': {'name': 'studio-native-check', 'version': '1'},
  });
  client.process.stdin.writeln(
    jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
  );
  final listed = (await client.request('tools/list', {}))['tools'] as List;
  require(
    listed.firstWhere(
          (tool) => tool['name'] == 'inspect_scene',
        )['annotations']['readOnlyHint'] ==
        true,
    'Diagnostics lost read-only annotation.',
  );
  final discovery = await client.tool('agent_discover', {});
  final providers = discovery['agentDiscovery']['providers'] as List;
  for (final id in [
    'zyren.studio',
    'zyren.viewport',
    'zyren.timeline',
    'zyren.engineering',
    'zyren.devtools',
  ]) {
    require(
      providers.any((p) => p['providerId'] == id),
      'Missing provider: $id',
    );
  }
  final studio = providers.firstWhere((p) => p['providerId'] == 'zyren.studio');
  Future<Map> query(
    String provider,
    String instance,
    String tool, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final envelope = await client.tool('agent_query', {
      'providerId': provider,
      'instanceId': instance,
      'tool': tool,
      'arguments': arguments,
    });
    final result = envelope['agentResult'] as Map;
    require(
      result['status'] == 'ok',
      '$provider/$tool query failed: ${result['status']}',
    );
    return result;
  }

  final before = await query('zyren.studio', studio['instanceId'], 'state');
  final screen = before['data']['screen'] as Map;
  require(
    (screen['agentProviderGaps'] as List).isEmpty,
    'Host has provider gaps.',
  );
  require(screen['pixelVisibility'] == 'unknown', 'Pixel evidence overstated.');
  require(screen['presentedFrame'] != null, 'No native frame was presented.');
  final pick = await query('zyren.viewport', 'main', 'pick', {
    'x': point['x'],
    'y': point['y'],
    'limit': 32,
  });
  require(
    pick['data']['frameCorrelation'] == 'unknown',
    'Frame correlation overstated.',
  );
  final hits = pick['data']['hits'] as List;
  final block = hits.firstWhere(
    (hit) =>
        hit['object']['metadata']['properties']['studio.nodeId'] == 'block',
  );
  require(
    block['object']['metadata']['sourceId'] == 'part:block',
    'Lost source ID.',
  );
  final review = await query('zyren.engineering', 'review', 'object', {
    'objectId': 'part:block',
  });
  require(review['data']['bound'] == true, 'Source record is not bound.');
  require(
    review['data']['properties']['origin'] == 'Studio fixture',
    'Wrong source record.',
  );
  require(
    (review['data']['annotations'] as List).isEmpty,
    'Private notes were exposed.',
  );
  final timeline = await query('zyren.timeline', 'camera-preview', 'inspect');
  require(
    timeline['data']['playing'] == false,
    'Preview did not release playback.',
  );

  final command = <String, Object?>{
    'providerId': 'zyren.studio',
    'instanceId': studio['instanceId'],
    'tool': 'transform',
    'expectedRevision': before['revision'],
    'idempotencyKey': 'native-mcp-move',
    'arguments': {
      'targetId': 'block',
      'position': [.25, 0, 0],
    },
  };
  final changed = await client.tool('agent_command', command);
  require(changed['agentResult']['status'] == 'ok', 'Native MCP edit failed.');
  final retried = await client.tool('agent_command', command);
  require(
    jsonEncode(retried) == jsonEncode(changed),
    'Retry changed its receipt.',
  );
  final stale = await client.tool('agent_command', {
    ...command,
    'idempotencyKey': 'native-mcp-stale',
  });
  require(
    stale['agentResult']['status'] == 'stale',
    'Old revision was accepted.',
  );
  final denied = await client.tool('agent_command', {
    'providerId': 'zyren.engineering',
    'instanceId': 'review',
    'tool': 'put_annotation',
    'expectedRevision': review['revision'],
    'idempotencyKey': 'native-denied-note',
    'arguments': {
      'id': 'private',
      'objectId': 'part:block',
      'text': 'denied',
      'anchor': [0, 0, 0],
    },
  });
  require(
    denied['agentResult']['status'] == 'denied',
    'Review mutation was accepted.',
  );
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    final after = await query('zyren.studio', studio['instanceId'], 'state');
    if (after['data']['screen']['presentedFrame']['id'] >
        screen['presentedFrame']['id']) {
      break;
    }
    require(
      DateTime.now().isBefore(deadline),
      'No presentation followed the edit.',
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final stats = await client.tool('capture_frame_stats', {'limit': 1});
  final frame = (stats['frames'] as List).single as Map;
  require(
    frame['presentationPath'] == 'nativeView',
    'Native presentation required.',
  );
  require(frame['readbackBytes'] == 0, 'Unexpected frame readback.');
  final capabilities = await client.tool('get_renderer_capabilities', {});
  stdout.writeln(
    'MCP verified five providers, source-bound geometry pick, edit, retry, '
    'stale rejection, permission denial and subsequent presentation. '
    'Backend: ${capabilities['backend']}; adapter: ${capabilities['adapterName']}; '
    'readback: ${frame['readbackBytes']} bytes.',
  );
}

class McpClient {
  final Process process;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  late final StreamSubscription<String> _output;
  late final Future<String> _errors;
  int _nextId = 0;
  McpClient(this.process) {
    _errors = process.stderr.transform(utf8.decoder).join();
    _output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final response = jsonDecode(line) as Map<String, dynamic>;
            final waiter = _pending.remove(response['id']);
            if (waiter == null) return;
            if (response['error'] != null) {
              waiter.completeError(
                StateError('MCP request failed: ${response['error']}'),
              );
            } else {
              waiter.complete(response['result'] as Map<String, dynamic>);
            }
          },
          onDone: () {
            for (final waiter in _pending.values) {
              waiter.completeError(
                StateError('MCP exited with a pending request.'),
              );
            }
            _pending.clear();
          },
        );
  }
  static Future<McpClient> start(Directory root, Map connection) async =>
      McpClient(
        await Process.start(
          Platform.resolvedExecutable,
          [
            '--packages=${root.path}/.dart_tool/package_config.json',
            '${root.path}/packages/zyren_devtools/bin/zyren.dart',
            'mcp',
          ],
          environment: {
            'ZYREN_DEVTOOLS_ENDPOINT': connection['endpoint'] as String,
            'ZYREN_DEVTOOLS_TOKEN': connection['token'] as String,
            'ZYREN_AGENT_TOOLS': '1',
          },
        ),
      );
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params,
  ) {
    final id = ++_nextId;
    final waiter = Completer<Map<String, dynamic>>();
    _pending[id] = waiter;
    process.stdin.writeln(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return waiter.future.timeout(const Duration(seconds: 15));
  }

  Future<Map<String, dynamic>> tool(
    String name,
    Map<String, Object?> arguments,
  ) async {
    final result = await request('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    return result['structuredContent'] as Map<String, dynamic>;
  }

  Future<void> close() async {
    try {
      await process.stdin.close();
      require(
        await process.exitCode.timeout(const Duration(seconds: 5)) == 0,
        'MCP process failed.',
      );
      require((await _errors).isEmpty, 'MCP wrote errors.');
    } finally {
      process.kill();
      await _output.cancel();
    }
  }
}
