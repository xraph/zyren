import 'dart:io';
import 'package:zyren_devtools/io.dart';

/// Bridge the host's existing authenticated devtools endpoint to MCP stdio.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1 ||
      Platform.environment['XR_DEVTOOLS_TOKEN'] == null) {
    stderr.writeln(
      'Usage: XR_DEVTOOLS_TOKEN=... dart run tool/mcp.dart http://127.0.0.1:8796/call',
    );
    exitCode = 64;
    return;
  }
  final client = DevtoolsClient(
    endpoint: Uri.parse(arguments.single),
    token: Platform.environment['XR_DEVTOOLS_TOKEN']!,
  );
  try {
    await serveDevtoolsMcp(
      input: stdin,
      output: stdout.writeln,
      call: client.call,
      agentsEnabled: true,
    );
  } finally {
    client.close();
  }
}
