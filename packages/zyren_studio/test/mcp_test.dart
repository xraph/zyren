import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_studio/agents.dart';
import 'package:zyren_studio/commands.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'support/renderer.dart';
import 'studio_test.dart' show fixture;

void main() {
  test(
    'external MCP CLI discovers Studio and edits through authenticated loopback',
    () async {
      final scene = StudioScene(fixture());
      final inspector = SceneDevtoolsPlugin();
      final engine = await SceneEngine.create(
        scene: scene.scene,
        camera: scene.camera,
        rendererFactory: () async => TestRenderer([]),
        plugins: [scene.tools, scene.engineering, inspector],
      );
      addTearDown(engine.dispose);
      final registry = AgentRegistry(grantedScopes: {'studio.edit'});
      addTearDown(registry.dispose);
      final commands = StudioCommands(
        scene: scene,
        sessionId: 'mcp-test',
        isAllowed: (_) => true,
        isAvailable: () => true,
      );
      addTearDown(commands.dispose);
      final provider = StudioAgentProvider(
        commands: commands,
        screenContext: () => {'viewportId': 'cpu-fixture'},
        hostRevision: () => 0,
      );
      registry.register(provider);
      final server = await DevtoolsServer.start(
        SceneDiagnostics(inspector),
        agents: registry,
      );
      addTearDown(server.close);
      var root = Directory.current;
      while (!File('${root.path}/pubspec.yaml').existsSync() ||
          !File(
            '${root.path}/pubspec.yaml',
          ).readAsStringSync().contains('name: zyren_workspace')) {
        if (root.parent.path == root.path) {
          throw StateError('Workspace root unavailable.');
        }
        root = root.parent;
      }
      final config = File('${root.path}/.dart_tool/package_config.json').uri;
      final cli = config.resolve('../packages/zyren_devtools/bin/zyren.dart');
      final process = await Process.start(
        Platform.environment['DART_EXECUTABLE'] ?? 'dart',
        ['--packages=${config.toFilePath()}', cli.toFilePath(), 'mcp'],
        environment: {
          'ZYREN_DEVTOOLS_ENDPOINT': server.endpoint.toString(),
          'ZYREN_DEVTOOLS_TOKEN': server.token,
          'ZYREN_AGENT_TOOLS': '1',
        },
      );
      addTearDown(() {
        process.kill();
      });
      final stderr = process.stderr.transform(utf8.decoder).join();
      final pending = <int, Completer<Map<String, dynamic>>>{};
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final value = jsonDecode(line) as Map<String, dynamic>;
            pending.remove(value['id'])?.complete(value);
          });
      addTearDown(output.cancel);
      var nextId = 0;
      Future<Map<String, dynamic>> request(
        String method,
        Map<String, Object?> params,
      ) {
        final id = ++nextId;
        final result = Completer<Map<String, dynamic>>();
        pending[id] = result;
        process.stdin.writeln(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'method': method,
            'params': params,
          }),
        );
        return result.future.timeout(const Duration(seconds: 20));
      }

      final initialized = await request('initialize', {
        'protocolVersion': '2025-11-25',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'studio-test', 'version': '1'},
      });
      expect(initialized['error'], isNull);
      process.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
      );
      final tools = await request('tools/list', {});
      final listed = tools['result']['tools'] as List;
      expect(listed.any((tool) => tool['name'] == 'agent_discover'), isTrue);
      expect(
        listed.firstWhere(
          (tool) => tool['name'] == 'inspect_scene',
        )['annotations']['readOnlyHint'],
        isTrue,
      );
      final discovered = await request('tools/call', {
        'name': 'agent_discover',
        'arguments': {},
      });
      expect(
        discovered['result']['structuredContent']['agentDiscovery']['providers'][0]['providerId'],
        provider.id,
      );
      final read = await request('tools/call', {
        'name': 'agent_query',
        'arguments': {
          'providerId': provider.id,
          'instanceId': provider.instanceId,
          'tool': 'state',
        },
      });
      expect(
        read['result']['structuredContent']['agentResult']['status'],
        'ok',
      );
      final changed = await request('tools/call', {
        'name': 'agent_command',
        'arguments': {
          'providerId': provider.id,
          'instanceId': provider.instanceId,
          'tool': 'transform',
          'expectedRevision': provider.revision,
          'idempotencyKey': 'mcp-move',
          'arguments': {
            'targetId': 'box',
            'position': [3, 2, 1],
          },
        },
      });
      expect(
        changed['result']['structuredContent']['agentResult']['status'],
        'ok',
      );
      expect(scene.objects['box']!.position, const Vec3(3, 2, 1));
      expect(scene.canUndo, isTrue);
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 5)), 0);
      expect(await stderr, isEmpty);
    },
  );
}
