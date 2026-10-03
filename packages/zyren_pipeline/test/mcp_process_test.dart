import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  test(
    'live shared MCP discovers, picks, mutates and rejects stale commands',
    () async {
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        'packages/zyren_pipeline/example/mcp_runtime.dart',
        if (Platform.environment['RUN_NATIVE_GPU'] == '1') '--native',
      ]);
      final errors = process.stderr.transform(utf8.decoder).join();
      final replies = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      addTearDown(() async {
        process.kill();
        await replies.cancel();
      });
      var id = 0;
      Future<Map<String, dynamic>> request(
        String method,
        Map<String, Object?> parameters,
      ) async {
        process.stdin.writeln(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': ++id,
            'method': method,
            'params': parameters,
          }),
        );
        expect(
          await replies.moveNext().timeout(const Duration(seconds: 30)),
          isTrue,
        );
        final response = jsonDecode(replies.current) as Map<String, dynamic>;
        expect(response['id'], id);
        expect(response['error'], isNull);
        return response['result'] as Map<String, dynamic>;
      }

      Future<Map> call(String name, Map<String, Object?> arguments) async =>
          (await request('tools/call', {
                'name': name,
                'arguments': arguments,
              }))['structuredContent']
              as Map;
      await request('initialize', {
        'protocolVersion': '2025-11-25',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'pipeline-check', 'version': '1'},
      });
      process.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
      );
      expect((await request('tools/list', {}))['tools'], isNotEmpty);
      final discovery =
          (await call('agent_discover', {}))['agentDiscovery'] as Map;
      final providers = discovery['providers'] as List;
      final pipeline =
          providers.firstWhere((p) => p['providerId'] == 'zyren.pipeline')
              as Map;
      final viewport =
          providers.firstWhere((p) => p['instanceId'] == 'main-view') as Map;
      final picked =
          (await call('agent_query', {
                'providerId': viewport['providerId'],
                'instanceId': 'main-view',
                'tool': 'pick',
                'arguments': {'x': 100, 'y': 50},
              }))['agentResult']
              as Map;
      expect(picked['status'], 'ok');
      final hit = (picked['data']['hits'] as List).single;
      expect(hit['object']['metadata']['sourceId'], 'part:triangle');
      expect(hit['renderedPixelVisibility'], 'unknown');
      final command = <String, Object?>{
        'providerId': 'zyren.pipeline',
        'instanceId': 'assets',
        'tool': 'invalidate-source',
        'arguments': {'sourceId': 'model'},
        'expectedRevision': pipeline['revision'],
        'idempotencyKey': 'invalidate-1',
      };
      final blocked =
          (await call('agent_query', command))['agentResult'] as Map;
      expect(blocked['status'], 'denied');
      final result =
          (await call('agent_command', command))['agentResult'] as Map;
      expect(result['status'], 'ok');
      expect(result['data']['removedCount'], 1);
      final retry =
          (await call('agent_command', command))['agentResult'] as Map;
      expect(retry, result);
      final stale =
          (await call('agent_command', {
                ...command,
                'idempotencyKey': 'invalidate-stale',
              }))['agentResult']
              as Map;
      expect(stale['status'], 'stale');
      final status =
          (await call('agent_query', {
                'providerId': 'zyren.pipeline',
                'instanceId': 'assets',
                'tool': 'status',
              }))['agentResult']
              as Map;
      expect(status['data']['cachedBundles'], 0);
      await process.stdin.close();
      expect(await process.exitCode, 0, reason: await errors);
    },
  );
}
