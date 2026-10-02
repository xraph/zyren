import 'dart:convert';
import 'dart:io';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_devtools/zyren_devtools.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.singleOrNull == '--help') {
    stdout.writeln(
      'Usage: dart run zyren_devtools:zyren <tool> [JSON arguments]\n'
      '       dart run zyren_devtools:zyren mcp\n'
      'Set ZYREN_AGENT_TOOLS=1 to expose an opt-in host agent registry over MCP.\n'
      'Set ZYREN_DEVTOOLS_ENDPOINT and ZYREN_DEVTOOLS_TOKEN from your debug session.\n'
      'Tools: ${SceneDiagnostics.tools.map((t) => t['name']).join(', ')}',
    );
    return;
  }
  DevtoolsClient? client;
  try {
    if (args.length > 2 || args.first == 'mcp' && args.length != 1) {
      throw const DiagnosticException(
        'invalidArguments',
        'Use one tool name and an optional JSON arguments object.',
      );
    }
    final endpoint = Platform.environment['ZYREN_DEVTOOLS_ENDPOINT'];
    final token = Platform.environment['ZYREN_DEVTOOLS_TOKEN'];
    if (endpoint == null || token == null) {
      throw const DiagnosticException(
        'configurationMissing',
        'Set ZYREN_DEVTOOLS_ENDPOINT and ZYREN_DEVTOOLS_TOKEN from your debug session.',
      );
    }
    client = DevtoolsClient(endpoint: Uri.parse(endpoint), token: token);
    if (args.first == 'mcp') {
      await serveDevtoolsMcp(
        input: stdin,
        output: stdout.writeln,
        call: client.call,
        agentsEnabled: Platform.environment['ZYREN_AGENT_TOOLS'] == '1',
      );
    } else {
      final arguments = args.length == 1
          ? <String, dynamic>{}
          : jsonDecode(args[1]);
      if (arguments is! Map<String, dynamic>) {
        throw const DiagnosticException(
          'invalidArguments',
          'Tool arguments must be a JSON object.',
        );
      }
      final result = await client.call(args.first, arguments);
      stdout.writeln(jsonEncode(result));
    }
  } on DiagnosticException catch (error) {
    stderr.writeln(jsonEncode({'error': error.toJson()}));
    exitCode = 1;
  } on FormatException {
    stderr.writeln(
      jsonEncode({
        'error': {
          'code': 'invalidArguments',
          'message': 'Use a valid endpoint and JSON arguments.',
        },
      }),
    );
    exitCode = 1;
  } on ArgumentError {
    stderr.writeln(
      jsonEncode({
        'error': {
          'code': 'invalidConfiguration',
          'message':
              'Use the loopback /call endpoint and token from your debug session.',
        },
      }),
    );
    exitCode = 1;
  } finally {
    client?.close();
  }
}
