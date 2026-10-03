import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/agents.dart';
import 'package:zyren_devtools/io.dart';
import '../../zyren_agents/test/registry_test.dart' show CounterProvider;

void main() {
  test(
    'MCP resource subscriptions notify changes and stop on unsubscribe/EOF',
    () async {
      final registry = AgentRegistry();
      final bridge = AgentDevtoolsBridge(registry);
      registry.register(CounterProvider());
      final input = StreamController<List<int>>();
      final responses = <Object, Completer<Map<String, dynamic>>>{};
      final updates = <Map<String, dynamic>>[];
      final notification = Completer<void>();
      final session = serveDevtoolsMcp(
        input: input.stream,
        agentsEnabled: true,
        call: bridge.call,
        output: (line) {
          final data = jsonDecode(line) as Map<String, dynamic>;
          if (data.containsKey('id')) {
            responses[data['id']]!.complete(data);
          } else {
            updates.add(data);
            if (!notification.isCompleted) notification.complete();
          }
        },
      );
      var id = 0;
      Future<Map<String, dynamic>> request(
        String method, [
        Map<String, Object?> params = const {},
      ]) {
        final next = ++id;
        final response = responses[next] = Completer();
        input.add(
          utf8.encode(
            '${jsonEncode({'jsonrpc': '2.0', 'id': next, 'method': method, 'params': params})}\n',
          ),
        );
        return response.future.timeout(const Duration(seconds: 3));
      }

      final initialized = await request('initialize', {
        'protocolVersion': '2025-11-25',
        'capabilities': {},
        'clientInfo': {'name': 'test', 'version': '1'},
      });
      expect(
        initialized['result']['capabilities']['resources']['subscribe'],
        true,
      );
      input.add(
        utf8.encode(
          '${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'})}\n',
        ),
      );
      final resources = await request('resources/list');
      final uri = resources['result']['resources'][0]['uri'] as String;
      await request('resources/subscribe', {'uri': uri});
      await registry.call(
        providerId: 'test.counter',
        instanceId: 'main',
        tool: 'read',
      );
      await notification.future.timeout(const Duration(seconds: 3));
      expect(updates.single['method'], 'notifications/resources/updated');
      final read = await request('resources/read', {'uri': uri});
      final contents =
          jsonDecode(read['result']['contents'][0]['text'] as String) as Map;
      expect(contents['events'], isNotEmpty);
      expect(
        (await request('resources/read', {
          'uri': 'file:///private',
        }))['error']['code'],
        -32002,
      );
      await request('resources/unsubscribe', {'uri': uri});
      await registry.call(
        providerId: 'test.counter',
        instanceId: 'main',
        tool: 'read',
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(updates, hasLength(1));
      await input.close();
      await session;
      bridge.dispose();
      registry.dispose();
    },
  );
}
