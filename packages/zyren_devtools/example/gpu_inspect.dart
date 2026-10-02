import 'dart:convert';
import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_devtools/gpu_tools.dart';
import 'package:zyren_devtools/gpu_bridge.dart';
import 'package:zyren_native/zyren_native.dart';

/// Run with --mcp for newline JSON-RPC, or without arguments for JSON output.
/// Local mode owns a separate device. Use --remote with the host bridge endpoint
/// and session token to query your running renderer.
Future<void> main(List<String> arguments) async {
  final inspector = SceneDevtoolsPlugin();
  SceneEngine? engine;
  GpuInspectionClient? client;
  final tools = GpuInspectionTools(inspector);
  if (arguments.contains('--remote')) {
    final endpoint = Platform.environment['ZYREN_GPU_ENDPOINT'];
    final token = Platform.environment['ZYREN_GPU_SESSION_TOKEN'];
    if (endpoint == null || token == null) {
      throw StateError('Set ZYREN_GPU_ENDPOINT and ZYREN_GPU_SESSION_TOKEN.');
    }
    client = GpuInspectionClient(
      endpoint: Uri.parse(endpoint),
      sessionToken: token,
    );
  } else {
    engine = await SceneEngine.create(
      scene: Scene()..add(Mesh(BoxGeometry(), UnlitMaterial())),
      camera: PerspectiveCamera()..position = const Vec3(0, 0, 4),
      backendFactory: NativeBackend.create,
      plugins: [inspector],
    );
  }
  Future<Map<String, Object?>> query(
    String name,
    Map<String, dynamic> args,
  ) async {
    final remote = client;
    if (remote == null) return tools.call(name, args);
    if (name != 'zyren_gpu_inspect' ||
        args.keys.any((key) => key != 'allocationLimit')) {
      throw ArgumentError('Unknown inspection tool or argument.');
    }
    final limit = args['allocationLimit'] ?? 128;
    if (limit is! int) {
      throw ArgumentError('allocationLimit must be an integer.');
    }
    return remote.inspectGpu(allocationLimit: limit);
  }

  try {
    await engine?.render(elapsed: Duration.zero, width: 32, height: 32);
    if (!arguments.contains('--mcp')) {
      stdout.writeln(jsonEncode(await query('zyren_gpu_inspect', {})));
      return;
    }
    var initialized = false;
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      Map<String, dynamic>? request;
      try {
        request = jsonDecode(line) as Map<String, dynamic>;
        if (!request.containsKey('id')) continue;
        final params = request['params'] as Map<String, dynamic>? ?? {};
        if (!initialized &&
            request['method'] != 'initialize' &&
            request['method'] != 'ping') {
          throw StateError('Initialize the MCP session before querying tools.');
        }
        final result = switch (request['method']) {
          'initialize' => {
            'protocolVersion': '2025-11-25',
            'capabilities': {'tools': {}},
            'serverInfo': {'name': 'zyren-gpu-inspection', 'version': '0.1.0'},
          },
          'tools/list' => {'tools': tools.tools},
          'tools/call' => {
            'content': [
              {
                'type': 'text',
                'text': jsonEncode(
                  await query(
                    params['name'] as String,
                    params['arguments'] as Map<String, dynamic>? ?? {},
                  ),
                ),
              },
            ],
          },
          'ping' => <String, Object?>{},
          _ => throw ArgumentError('Unknown method.'),
        };
        initialized = initialized || request['method'] == 'initialize';
        stdout.writeln(
          jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
        );
      } catch (error) {
        stdout.writeln(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': request?['id'],
            'error': {'code': -32602, 'message': error.toString()},
          }),
        );
      }
    }
  } finally {
    client?.close();
    await engine?.dispose();
  }
}
