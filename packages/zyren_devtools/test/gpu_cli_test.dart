import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  test(
    'native CLI and MCP keep stdout structured and require initialization',
    () async {
      var workspace = Directory.current;
      while (!File(
        '${workspace.path}/packages/zyren_devtools/example/gpu_inspect.dart',
      ).existsSync()) {
        final parent = workspace.parent;
        if (parent.path == workspace.path) {
          throw StateError('Workspace not found.');
        }
        workspace = parent;
      }
      final script =
          '${workspace.path}/packages/zyren_devtools/example/gpu_inspect.dart';
      final cli = await Process.run(Platform.resolvedExecutable, [
        'run',
        script,
      ], workingDirectory: workspace.path);
      expect(cli.exitCode, 0, reason: cli.stderr.toString());
      final snapshot = jsonDecode(cli.stdout as String) as Map;
      expect(snapshot['residentBytes'], isNull);
      expect(snapshot['submittedFrames'], 1);
      expect(snapshot['allocations'], isA<List>());
      expect(snapshot['memoryReports'], isNotEmpty);
      if (snapshot['deviceAllocationSource'] == 'metal.currentAllocatedSize') {
        expect(snapshot['deviceAllocatedBytes'], greaterThan(0));
        expect(snapshot['lastSubmissionGpuTimeNs'], greaterThan(0));
      }
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        script,
        '--mcp',
      ], workingDirectory: workspace.path);
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      for (final request in [
        {'jsonrpc': '2.0', 'id': 0, 'method': 'tools/list'},
        {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'},
        {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
        {
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'tools/call',
          'params': {
            'name': 'zyren_gpu_inspect',
            'arguments': {'allocationLimit': 1},
          },
        },
        {
          'jsonrpc': '2.0',
          'id': 4,
          'method': 'tools/call',
          'params': {
            'name': 'zyren_gpu_inspect',
            'arguments': {'allocationLimit': 257},
          },
        },
      ]) {
        process.stdin.writeln(jsonEncode(request));
      }
      await process.stdin.close();
      expect(await process.exitCode, 0, reason: await errors);
      final replies = const LineSplitter()
          .convert(await output)
          .map((line) => jsonDecode(line) as Map)
          .toList();
      expect(replies.map((reply) => reply['id']), [0, 1, 2, 3, 4]);
      expect(replies.first['error'], isNotNull);
      expect(
        (replies[2]['result'] as Map)['tools'][0]['name'],
        'zyren_gpu_inspect',
      );
      final inspection =
          jsonDecode(replies[3]['result']['content'][0]['text'] as String)
              as Map;
      expect((inspection['allocations'] as List).length, lessThanOrEqualTo(1));
      expect(inspection['residentBytes'], isNull);
      expect(inspection['memoryReports'], isNotEmpty);
      if (snapshot['deviceAllocationSource'] == 'metal.currentAllocatedSize') {
        final memory = (inspection['memoryReports'] as List).single as Map;
        expect(memory['source'], 'metal.deviceMemory');
        expect(memory['scope'], 'processDevice');
        expect(memory['usageBytes'], greaterThan(0));
        expect(memory['recommendedMaxWorkingSetBytes'], greaterThan(0));
        expect(memory['budgetBytes'], isNull);
      }
      expect(replies.last['error'], isNotNull);
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
