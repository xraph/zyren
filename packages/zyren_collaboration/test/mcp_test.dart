import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_collaboration/agent_provider.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  test(
    'live stdio MCP discovers, picks and edits through the existing bridge',
    () async {
      final source = SceneObjectId(source: 'assembly', key: 'housing');
      final authority = LocalSceneAuthority(
        initial: SceneSnapshot(
          sceneId: 'scene',
          epoch: 'session',
          objects: [SceneObjectState(id: source)],
        ),
        canRead: (_, _) => true,
        canWrite: (_, _, _) => true,
      );
      var sequence = 0;
      final client = SceneCollaborationClient(
        transport: authority.connect('host'),
        sceneId: 'scene',
        epoch: 'session',
        nextOperationId: () => 'op-${++sequence}',
      );
      await client.refresh();
      final scene = Scene(),
          camera = PerspectiveCamera(position: const Vec3(0, 0, 5));
      final object = scene.add(
        Mesh(BoxGeometry(), UnlitMaterial(), name: 'Housing'),
      );
      final inspector = SceneDevtoolsPlugin(),
          collaboration = SceneCollaborationPlugin(client);
      final registry = AgentRegistry(
        grantedScopes: {'collaboration.read', 'collaboration.write'},
      );
      final agent = SceneCollaborationAgentPlugin(
        collaboration: collaboration,
        registry: registry,
        instanceId: 'shared',
        documentId: 'document',
      );
      final renderer = TestRenderer([]);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        rendererFactory: () async => renderer,
        plugins: [inspector, collaboration, agent],
      );
      collaboration.binding.rebind({source: object});
      final viewport = AgentViewportProvider(
        sceneId: 'scene',
        documentId: 'document',
        instanceId: 'view',
        scene: scene,
        camera: () => camera,
        viewport: () => const ViewportMetrics(200, 100, devicePixelRatio: 2),
        documentRevision: () => client.snapshot!.revision,
        metadata: agent.provider!.metadataFor,
      );
      registry.register(viewport);
      final server = await DevtoolsServer.start(
        SceneDiagnostics(inspector),
        agents: registry,
      );
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:zyren_devtools/zyren_devtools.dart'),
      );
      final executable = File.fromUri(
        library!.resolve('../bin/zyren.dart'),
      ).path;
      final process = await Process.start(
        Platform.resolvedExecutable,
        [executable, 'mcp'],
        environment: {
          'ZYREN_DEVTOOLS_ENDPOINT': server.endpoint.toString(),
          'ZYREN_DEVTOOLS_TOKEN': server.token,
          'ZYREN_AGENT_TOOLS': '1',
        },
      );
      final stderrResult = process.stderr.transform(utf8.decoder).join();
      final pending = <int, Completer<Map<String, dynamic>>>{};
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final value = jsonDecode(line) as Map<String, dynamic>;
            pending.remove(value['id'])?.complete(value);
          });
      var requestId = 0;
      Future<Map<String, dynamic>> rpc(
        String method,
        Map<String, Object?> params,
      ) {
        final id = ++requestId, result = Completer<Map<String, dynamic>>();
        pending[id] = result;
        process.stdin.writeln(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'method': method,
            'params': params,
          }),
        );
        return result.future.timeout(const Duration(seconds: 10));
      }

      Future<Map<String, dynamic>> tool(
        String name,
        Map<String, Object?> args,
      ) async {
        final response = await rpc('tools/call', {
          'name': name,
          'arguments': args,
        });
        expect(response['error'], isNull);
        return response['result'] as Map<String, dynamic>;
      }

      try {
        final initialized = await rpc('initialize', {
          'protocolVersion': '2025-11-25',
          'capabilities': {},
          'clientInfo': {'name': 'collaboration-check', 'version': '1'},
        });
        expect(initialized['error'], isNull);
        process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
        final listed = await rpc('tools/list', {});
        final tools = listed['result']['tools'] as List;
        expect(
          tools.firstWhere(
            (tool) => tool['name'] == 'agent_command',
          )['annotations']['readOnlyHint'],
          isFalse,
        );
        for (final original in SceneDiagnostics.tools) {
          expect(
            tools.firstWhere((tool) => tool['name'] == original['name']),
            original,
          );
        }
        final discovered = await tool('agent_discover', {});
        final providers =
            discovered['structuredContent']['agentDiscovery']['providers']
                as List;
        expect(
          providers.map((value) => value['providerId']),
          containsAll(['zyren.collaboration', 'zyren.viewport']),
        );
        final picked = await tool('agent_query', {
          'providerId': viewport.id,
          'instanceId': viewport.instanceId,
          'tool': 'pick',
          'arguments': {'x': 100, 'y': 50},
        });
        final hit =
            (picked['structuredContent']['agentResult']['data']['hits'] as List)
                .single;
        expect(hit['object']['metadata']['sourceId'], source.toString());
        expect(hit['object']['runtimeId'], object.id);
        expect(hit['renderedPixelVisibility'], 'unknown');
        final arguments = <String, Object?>{
          'providerId': agent.provider!.id,
          'instanceId': agent.provider!.instanceId,
          'tool': 'set_visibility',
          'arguments': {
            'source': 'assembly',
            'key': 'housing',
            'visible': false,
          },
          'expectedRevision': agent.provider!.revision,
          'idempotencyKey': 'hide',
        };
        final denied = await tool('agent_query', arguments);
        expect(denied['structuredContent']['agentResult']['status'], 'denied');
        expect(object.visible, isTrue);
        final changed = await tool('agent_command', arguments);
        expect(changed['structuredContent']['agentResult']['status'], 'ok');
        expect(object.visible, isFalse);
        expect(client.snapshot!.revision, 1);
        expect(
          (await tool(
            'agent_command',
            arguments,
          ))['structuredContent']['agentResult']['status'],
          'ok',
        );
        expect(client.snapshot!.revision, 1);
        final diagnostic = await tool('inspect_scene', {});
        expect(diagnostic['structuredContent']['totalNodes'], 1);
        expect(renderer.renders, 0);
        await process.stdin.close();
        expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
        expect(await stderrResult, isEmpty);
      } finally {
        process.kill();
        await output.cancel();
        await server.close();
        registry.dispose();
        await engine.dispose();
        await client.close();
      }
    },
  );
}
