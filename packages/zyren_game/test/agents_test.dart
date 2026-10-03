import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/agents.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_game/agents.dart';
import 'package:zyren_game/zyren_game.dart';
import 'save_replay_test.dart' as fixture;

void main() {
  test(
    'live MCP inspect pause and manual step share scoped registry and history',
    () async {
      final session = fixture.game();
      final registry = AgentRegistry(grantedScopes: {'game.control'});
      final diagnostics = SceneDiagnostics(SceneDevtoolsPlugin());
      final provider = GameAgentProvider(
        session: () => session,
        instanceId: 'play',
        diagnostics: diagnostics,
      );
      final registration = provider.attach(registry);
      final bridge = AgentDevtoolsBridge(registry);
      final input = StreamController<List<int>>();
      final pending = <int, Completer<Map<String, dynamic>>>{};
      final server = serveDevtoolsMcp(
        input: input.stream,
        output: (line) {
          final value = jsonDecode(line) as Map<String, dynamic>;
          final id = value['id'];
          if (id is int) pending.remove(id)?.complete(value);
        },
        agentsEnabled: true,
        call: bridge.call,
      );
      var id = 0;
      Future<Map<String, dynamic>> call(
        String method,
        Map<String, Object?> params,
      ) {
        final next = ++id, completer = Completer<Map<String, dynamic>>();
        pending[next] = completer;
        input.add(
          utf8.encode(
            '${jsonEncode({'jsonrpc': '2.0', 'id': next, 'method': method, 'params': params})}\n',
          ),
        );
        return completer.future;
      }

      Future<Map<String, dynamic>> tool(
        String name, {
        bool mutation = false,
      }) async {
        final response = await call('tools/call', {
          'name': mutation ? 'agent_command' : 'agent_query',
          'arguments': {
            'providerId': provider.id,
            'instanceId': provider.instanceId,
            'tool': name,
            if (mutation) 'expectedRevision': provider.revision,
            if (mutation) 'idempotencyKey': 'command-$id',
          },
        });
        final result =
            response['result']['structuredContent']['agentResult']
                as Map<String, dynamic>;
        expect(result['status'], 'ok');
        return result['data'] as Map<String, dynamic>;
      }

      try {
        await call('initialize', {
          'protocolVersion': '2025-11-25',
          'capabilities': {},
          'clientInfo': {'name': 'game-test', 'version': '1'},
        });
        input.add(
          utf8.encode(
            '${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'})}\n',
          ),
        );
        expect((await tool('inspect'))['status'], 'running');
        expect((await tool('pause', mutation: true))['status'], 'paused');
        final stepped = await tool('step', mutation: true);
        expect(stepped['status'], 'paused');
        expect(stepped['tick'], 1);
        expect(
          (diagnostics.call('get_scene_issues')['issues'] as List),
          isNotEmpty,
        );
        await session.close();
        expect((await tool('inspect'))['status'], 'missing');
      } finally {
        await input.close();
        await server;
        registration.dispose();
        bridge.dispose();
        registry.dispose();
        await session.close();
      }
    },
  );
  test('missing session and unauthorized mutation remain distinct', () async {
    final registry = AgentRegistry();
    final session = fixture.game();
    final provider = GameAgentProvider(
      session: () => session,
      instanceId: 'denied',
    );
    final lease = provider.attach(registry);
    final result = await registry.call(
      providerId: provider.id,
      instanceId: provider.instanceId,
      tool: 'pause',
      arguments: {},
      expectedRevision: provider.revision,
      idempotencyKey: 'one',
    );
    expect(result.status, AgentStatus.denied);
    expect(session.paused, isFalse);
    expect(GameDiagnostics(() => null).snapshot()['status'], 'missing');
    lease.dispose();
    registry.dispose();
    await session.close();
  });
}
