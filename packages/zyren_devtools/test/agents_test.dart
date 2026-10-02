import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/agents.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import '../../zyren/test/support/fakes.dart';
import '../../zyren_agents/test/registry_test.dart' show CounterProvider;

void main() {
  test(
    'existing inspector provider uses shared schemas and exposes current diagnostics',
    () async {
      final scene = Scene()..add(Mesh(BoxGeometry(), UnlitMaterial()));
      final inspector = SceneDevtoolsPlugin();
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [inspector],
      );
      final registry = AgentRegistry();
      final provider = DiagnosticsAgentProvider(
        diagnostics: SceneDiagnostics(inspector),
        inspector: inspector,
        instanceId: 'view',
      );
      final lease = registry.register(provider);
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'inspect_scene',
        ),
        isEmpty,
      );
      final result = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'inspect_scene',
      );
      expect(result.data['totalNodes'], 1);
      expect(provider.tools.every((tool) => tool.readOnly), isTrue);
      lease.dispose();
      registry.dispose();
      await engine.dispose();
    },
  );
  test(
    'real loopback agent calls preserve read-only separation, scopes and retries',
    () async {
      final inspector = SceneDevtoolsPlugin();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [inspector],
      );
      final registry = AgentRegistry(grantedScopes: {'counter.write'});
      final provider = CounterProvider();
      registry.register(provider);
      final server = await DevtoolsServer.start(
        SceneDiagnostics(inspector),
        agents: registry,
      );
      final client = DevtoolsClient(
        endpoint: server.endpoint,
        token: server.token,
      );
      try {
        expect(
          (await client.call('agent_discover'))['agentDiscovery'],
          isA<Map>(),
        );
        final args = <String, Object?>{
          'providerId': provider.id,
          'instanceId': provider.instanceId,
          'tool': 'increment',
          'arguments': {'amount': 1},
          'expectedRevision': 0,
          'idempotencyKey': 'one',
        };
        expect(
          (await client.call('agent_query', args))['agentResult'],
          containsPair('status', 'denied'),
        );
        expect(provider.count, 0);
        expect(
          (await client.call('agent_command', args))['agentResult'],
          containsPair('status', 'ok'),
        );
        expect(
          (await client.call('agent_command', args))['agentResult'],
          containsPair('status', 'ok'),
        );
        expect(provider.count, 1);
        expect((await client.call('inspect_scene'))['totalNodes'], 0);
      } finally {
        client.close();
        await server.close();
        registry.dispose();
        await engine.dispose();
      }
    },
  );
  test(
    'opt-in MCP preserves diagnostics annotations and marks agent command failures',
    () async {
      final registry = AgentRegistry();
      final provider = CounterProvider();
      registry.register(provider);
      final bridge = AgentDevtoolsBridge(registry);
      final requests = [
        {
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': {
            'protocolVersion': '2025-11-25',
            'capabilities': {},
            'clientInfo': {'name': 'test', 'version': '1'},
          },
        },
        {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
        {
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'tools/call',
          'params': {
            'name': 'agent_command',
            'arguments': {
              'providerId': provider.id,
              'instanceId': provider.instanceId,
              'tool': 'increment',
              'arguments': {'amount': 1},
              'expectedRevision': 0,
              'idempotencyKey': 'one',
            },
          },
        },
      ];
      final outputs = <Map<String, dynamic>>[];
      await serveDevtoolsMcp(
        input: Stream.value(
          utf8.encode('${requests.map(jsonEncode).join('\n')}\n'),
        ),
        output: (line) => outputs.add(jsonDecode(line) as Map<String, dynamic>),
        agentsEnabled: true,
        call: bridge.call,
      );
      final tools = outputs[1]['result']['tools'] as List;
      for (final original in SceneDiagnostics.tools) {
        expect(
          tools.firstWhere((tool) => tool['name'] == original['name']),
          equals(original),
        );
      }
      expect(
        tools.firstWhere(
          (tool) => tool['name'] == 'agent_query',
        )['annotations']['readOnlyHint'],
        true,
      );
      expect(
        tools.firstWhere(
          (tool) => tool['name'] == 'agent_command',
        )['annotations']['readOnlyHint'],
        false,
      );
      expect(outputs.last['result']['isError'], true);
      expect(
        outputs.last['result']['structuredContent']['agentResult']['status'],
        'denied',
      );
      registry.dispose();
    },
  );
}
