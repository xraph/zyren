import 'dart:convert';
import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_devtools/gpu_tools.dart';
import 'package:zyren_native/zyren_native.dart';

/// Run with --mcp for newline JSON-RPC, or without arguments for JSON output.
/// This example owns a separate device. Embed GpuInspectionTools in your host
/// to inspect that host's attached renderer instead.
Future<void> main(List<String> arguments) async {
  final inspector = SceneDevtoolsPlugin();
  final engine = await SceneEngine.create(
    scene: Scene()..add(Mesh(BoxGeometry(), UnlitMaterial())),
    camera: PerspectiveCamera()..position = const Vec3(0, 0, 4),
    backendFactory: NativeBackend.create,
    plugins: [inspector],
  );
  final tools = GpuInspectionTools(inspector);
  try {
    await engine.render(elapsed: Duration.zero, width: 32, height: 32);
    if (!arguments.contains('--mcp')) {
      stdout.writeln(jsonEncode(await tools.call('zyren_gpu_inspect', {})));
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
                  await tools.call(
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
    await engine.dispose();
  }
}
