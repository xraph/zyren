import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_native/scene.dart';
import 'package:zyren_game_studio/agents.dart';
import 'package:zyren_game_studio/authoring_agents.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_game_studio/export.dart';
import 'package:zyren_game_studio/export_io.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_studio/agents.dart';
import 'package:zyren_studio/commands.dart';
import 'package:zyren_studio/zyren_studio.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  test(
    'external stdio MCP inspects edits undoes and builds a real offline file',
    () async {
      final directory = await Directory.systemTemp.createTemp('game-mcp-');
      final authoring = createGameDevelopmentAuthoring();
      final document = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'mcp').document;
      final scene = StudioScene(
        document,
        extensionRegistry: StudioExtensionRegistry()..register(authoring.codec),
      );
      final registry = AgentRegistry(
        grantedScopes: {'studio.edit', 'game.read', 'game.build'},
      );
      final target = File('${directory.path}/exports/mcp.zygame');
      final builds = GameBuildCommands(
        compiler: GameProjectCompiler(
          registry: authoring.registry,
          assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
        ),
        documents: () => [scene.capture()],
        revision: () => scene.revision,
        startupLevel: () => 'main',
        profile: () => GameLevelAuthoring(authoring).profile(scene.document),
        allows: (_) => true,
        isAvailable: () => true,
        publish: GameFilePublisher(target).publish,
        outputLabel: target.path,
      );
      final builder = GameStudioAgentProvider(
        commands: builds,
        instanceId: 'game',
      );
      final buildLease = builder.attach(registry);
      final edits = GameAuthoringAgent(
        authoring: authoring,
        scene: scene,
        isAvailable: () => true,
        applyDocument: scene.apply,
        instanceId: 'game',
      );
      registry.register(edits);
      final studio = StudioAgentProvider(
        commands: StudioCommands(
          scene: scene,
          sessionId: 'game',
          isAllowed: (_) => true,
          isAvailable: () => true,
        ),
        screenContext: () => const {},
        hostRevision: () => 0,
      );
      registry.register(studio);
      final inspector = SceneDevtoolsPlugin();
      final engine = await SceneEngine.create(
        scene: scene.scene,
        camera: scene.camera,
        rendererFactory: () async => TestRenderer([]),
        plugins: [inspector],
      );
      final server = await DevtoolsServer.start(
        SceneDiagnostics(inspector),
        agents: registry,
      );
      final config = File('../../.dart_tool/package_config.json').absolute;
      final configData = jsonDecode(await config.readAsString()) as Map;
      final packages = configData['packages'] as List;
      final devtools = packages.firstWhere(
        (p) => p['name'] == 'zyren_devtools',
      );
      final root = config.uri.resolve('${devtools['rootUri']}/');
      final dart = Platform.resolvedExecutable.endsWith('/dart')
          ? Platform.resolvedExecutable
          : File.fromUri(
              Uri.parse(
                '${configData['flutterRoot']}/',
              ).resolve('bin/cache/dart-sdk/bin/dart'),
            ).path;
      final process = await Process.start(
        dart,
        [
          '--packages=${config.path}',
          File.fromUri(root.resolve('bin/zyren.dart')).path,
          'mcp',
        ],
        environment: {
          'ZYREN_DEVTOOLS_ENDPOINT': server.endpoint.toString(),
          'ZYREN_DEVTOOLS_TOKEN': server.token,
          'ZYREN_AGENT_TOOLS': '1',
        },
      );
      final errors = process.stderr.transform(utf8.decoder).join();
      final pending = <int, Completer<Map<String, dynamic>>>{};
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final result = jsonDecode(line) as Map<String, dynamic>;
            pending.remove(result['id'])?.complete(result);
          });
      var sequence = 0;
      Future<Map<String, dynamic>> rpc(
        String method,
        Map<String, Object?> params,
      ) {
        final id = ++sequence, result = Completer<Map<String, dynamic>>();
        pending[id] = result;
        process.stdin.writeln(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'method': method,
            'params': params,
          }),
        );
        return result.future.timeout(const Duration(seconds: 15));
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
        return response['result']['structuredContent']['agentResult']
            as Map<String, dynamic>;
      }

      Map<String, Object?> call(
        AgentProvider provider,
        String tool,
        Map<String, Object?> args, {
        String? key,
        int? revision,
      }) => {
        'providerId': provider.id,
        'instanceId': provider.instanceId,
        'tool': tool,
        'arguments': args,
        'idempotencyKey': ?key,
        'expectedRevision': ?revision,
      };
      try {
        expect(
          (await rpc('initialize', {
            'protocolVersion': '2025-11-25',
            'capabilities': {},
            'clientInfo': {'name': 'game-export-check', 'version': '1'},
          }))['error'],
          isNull,
        );
        process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
        final info = await tool('agent_query', call(builder, 'inspect', {}));
        final registration = info['data']['registrationId'];
        final buildArgs = {
          'registrationId': registration,
          'documentRevision': scene.revision,
        };
        final denied = await tool(
          'agent_query',
          call(
            builder,
            'build',
            buildArgs,
            key: 'denied',
            revision: builder.revision,
          ),
        );
        expect(denied['status'], 'denied');
        expect(builds.jobs, isEmpty);
        final stale = await tool(
          'agent_command',
          call(
            builder,
            'build',
            {...buildArgs, 'documentRevision': scene.revision + 1},
            key: 'stale',
            revision: builder.revision,
          ),
        );
        expect(stale['status'], 'stale');
        expect(builds.jobs, isEmpty);
        expect(await target.parent.exists(), isFalse);
        final before = authoring
            .expanded(scene.document)
            .entities
            .firstWhere((e) => e.id == 'player')
            .components
            .firstWhere((c) => c.type == 'game.character')
            .data['maxSpeed'];
        final changed = await tool(
          'agent_command',
          call(
            edits,
            'set_fields',
            {
              'nodeId': 'player',
              'component': 'game.character',
              'fields': {'maxSpeed': 2},
            },
            key: 'edit',
            revision: edits.revision,
          ),
        );
        expect(changed['status'], 'ok');
        expect(scene.canUndo, isTrue);
        final undone = await tool(
          'agent_command',
          call(studio, 'undo', {}, key: 'undo', revision: studio.revision),
        );
        expect(undone['status'], 'ok');
        expect(
          authoring
              .expanded(scene.document)
              .entities
              .firstWhere((e) => e.id == 'player')
              .components
              .firstWhere((c) => c.type == 'game.character')
              .data['maxSpeed'],
          before,
        );
        final built = await tool(
          'agent_command',
          call(
            builder,
            'build',
            {
              'registrationId': registration,
              'documentRevision': scene.revision,
            },
            key: 'export',
            revision: builder.revision,
          ),
        );
        expect(built['status'], 'ok');
        await builds.jobs.single.done;
        expect(await target.exists(), isTrue);
        await process.stdin.close();
        expect(await process.exitCode.timeout(const Duration(seconds: 15)), 0);
        expect(await errors, isEmpty);
        await server.close();
        buildLease.dispose();
        await builds.close();
        registry.dispose();
        await engine.dispose();
        final offline = GameExportManifest.decodeBundle(
          await target.readAsBytes(),
          authoring.registry,
        );
        expect(offline.project.project.id, 'mcp');
        final loaded = await GameRuntimeScene.load(offline.project);
        final runtime = GameLevelRuntime(
          project: offline.project,
          scene: loaded.scene,
          camera: loaded.camera,
          objects: loaded.objects,
          capabilities: offline.project.capabilityRequirements.toSet(),
          resources: [GameRuntimeResourceLease(close: loaded.close)],
        );
        await runtime.initialize();
        final offlineEngine = await SceneEngine.create(
          scene: loaded.scene,
          camera: loaded.camera,
          rendererFactory: () async => TestRenderer([]),
          plugins: runtime.plugins,
        );
        try {
          runtime.simulation!.step();
          final actor = runtime.inputActor!;
          final before = runtime.resolveBody(actor)!.state.pose.position;
          runtime.actions!.setAxis(
            deviceId: 'offline',
            action: 'move.z',
            value: 1,
          );
          for (var i = 0; i < 10; i++) {
            runtime.simulation!.step();
          }
          expect(
            runtime.resolveBody(actor)!.state.pose.position.distanceTo(before),
            greaterThan(.1),
          );
        } finally {
          await offlineEngine.dispose();
          await runtime.close();
        }
      } finally {
        process.kill();
        await output.cancel();
        await server.close();
        buildLease.dispose();
        await builds.close();
        registry.dispose();
        await engine.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
