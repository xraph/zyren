import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:test/test.dart';

void main() {
  test(
    'live stdio MCP discovers, picks character geometry and applies playback',
    () async {
      // Reuse this test run's built assets. A nested `dart run` can overwrite
      // the workspace manifest while another package is using native hooks.
      final scratch = await Directory.systemTemp.createTemp('character-mcp-');
      addTearDown(() => scratch.delete(recursive: true));
      final config = (await Isolate.packageConfig)!;
      final localAssets = File('.dart_tool/native_assets.yaml');
      final assets = await localAssets.exists()
          ? localAssets
          : File.fromUri(config.resolve('native_assets.yaml'));
      final snapshot = await assets.copy('${scratch.path}/native_assets.yaml');
      expect(await snapshot.readAsString(), contains('package:zyren_physics/'));
      final sdk = File(Platform.resolvedExecutable).parent.parent.uri;
      final suffix = Platform.isWindows ? '.exe' : '';
      final kernel = '${scratch.path}/host.dill';
      final compiled = await Process.run(
        sdk.resolve('bin/dartaotruntime$suffix').toFilePath(),
        [
          sdk
              .resolve('bin/snapshots/gen_kernel_aot.dart.snapshot')
              .toFilePath(),
          '--platform',
          sdk.resolve('lib/_internal/vm_platform_strong.dill').toFilePath(),
          '--packages',
          config.toFilePath(),
          '--native-assets',
          snapshot.path,
          '--output',
          kernel,
          'test/support/agent_mcp_host.dart',
        ],
      ).timeout(const Duration(minutes: 2));
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}\n${compiled.stderr}',
      );
      final process = await Process.start(Platform.resolvedExecutable, [
        kernel,
      ]);
      final errors = process.stderr.transform(utf8.decoder).join();
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      var serial = 0;
      Future<Map<String, dynamic>> request(
        String method,
        Map<String, Object?> params,
      ) async {
        final id = ++serial;
        process.stdin.writeln(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'method': method,
            'params': params,
          }),
        );
        while (await lines.moveNext().timeout(const Duration(seconds: 30))) {
          final line = lines.current;
          if (!line.startsWith('{')) {
            continue; // Dart hook progress is not protocol data.
          }
          final response = jsonDecode(line) as Map<String, dynamic>;
          if (response['id'] == id) {
            expect(response['error'], isNull);
            return response['result'] as Map<String, dynamic>;
          }
        }
        throw StateError('MCP host exited: ${await errors}');
      }

      Future<Map<String, dynamic>> tool(
        String name,
        Map<String, Object?> arguments,
      ) async =>
          (await request('tools/call', {
                'name': name,
                'arguments': arguments,
              }))['structuredContent']
              as Map<String, dynamic>;
      try {
        final initialized = await request('initialize', {
          'protocolVersion': '2025-11-25',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'character-qualification', 'version': '1'},
        });
        expect(initialized['protocolVersion'], '2025-11-25');
        process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
        final listed = await request('tools/list', {});
        expect(
          (listed['tools'] as List).map((t) => t['name']),
          containsAll([
            'inspect_scene',
            'agent_discover',
            'agent_query',
            'agent_command',
          ]),
        );
        final discovered = await tool('agent_discover', {});
        final providers = discovered['agentDiscovery']['providers'] as List;
        expect(providers.length, 6);
        final character =
            providers.singleWhere((p) => p['providerId'] == 'zyren.characters')
                as Map;
        final hit = (await tool('agent_query', {
          'providerId': 'zyren.viewport',
          'instanceId': 'main',
          'tool': 'pick',
          'arguments': {'x': 240, 'y': 180},
        }))['agentResult'];
        expect(hit['status'], 'ok');
        expect(hit['data']['frameCorrelation'], 'unknown');
        final first = (hit['data']['hits'] as List).first;
        expect(first['renderedPixelVisibility'], 'unknown');
        expect(
          first['object']['metadata']['properties']['characterState'],
          'idle',
        );
        final parameters = {
          'providerId': 'zyren.characters',
          'instanceId': 'robot',
          'tool': 'playback',
          'arguments': {'action': 'transition', 'state': 'walk'},
          'expectedRevision': character['revision'],
          'idempotencyKey': 'walk-1',
        };
        final changed = (await tool(
          'agent_command',
          parameters,
        ))['agentResult'];
        expect(changed['status'], 'ok');
        expect(changed['data']['state'], 'walk');
        final retry = (await tool('agent_command', parameters))['agentResult'];
        expect(retry['revision'], changed['revision']);
        final deniedMutation = (await tool('agent_query', {
          'providerId': 'zyren.characters',
          'instanceId': 'robot',
          'tool': 'playback',
          'arguments': {'action': 'pause'},
        }))['agentResult'];
        expect(deniedMutation['status'], 'denied');
        final diagnostics = await tool('inspect_scene', {});
        expect(diagnostics['error'], isNull);
        await process.stdin.close();
        expect(
          await process.exitCode.timeout(const Duration(seconds: 10)),
          0,
          reason: await errors,
        );
      } finally {
        process.kill();
        await lines.cancel();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
