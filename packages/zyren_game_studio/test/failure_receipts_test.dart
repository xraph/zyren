import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio/commands.dart';
import 'package:zyren_game_studio/agents.dart';
import 'package:zyren_game_studio/export.dart';
import 'package:zyren_game_studio/export_io.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

// This renderer attaches editor tools only. No render or GPU evidence is claimed.
final class CommandRenderer implements SceneRenderer {
  @override
  RendererCapabilities get capabilities =>
      RendererCapabilities(name: 'command-only', features: {}, maxDimension: 1);
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) async => throw StateError('Command receipt tests do not render.');
  @override
  Future<void> dispose() async {}
}

final class BuildFixture {
  final authoring = createGameDevelopmentAuthoring();
  late final StudioDocument document = GameTemplate(
    GameTemplateKind.exploration,
    authoring,
  ).create(projectId: 'failure-tools').document;
  final Directory directory;
  late final File target = File('${directory.path}/output/game.zygame');
  final ready = Completer<void>(), release = Completer<void>();
  bool hold = false;
  int publications = 0;
  BuildFixture(this.directory);
  GameBuildCommands commands() => GameBuildCommands(
    compiler: GameProjectCompiler(
      registry: authoring.registry,
      assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
    ),
    documents: () => [document],
    revision: () => 1,
    startupLevel: () => 'main',
    profile: () => GameLevelAuthoring(authoring).profile(document),
    allows: (_) => true,
    isAvailable: () => true,
    outputLabel: target.path,
    publish: (bundle, token, check) async {
      if (hold) {
        ready.complete();
        await release.future;
      }
      await GameFilePublisher(target).publish(bundle, token, check);
      publications++;
    },
  );
  Map<String, Object?> identity(GameBuildCommands commands) => {
    'document': document.encode(),
    'documentRevision': commands.revision(),
    'outputExists': target.existsSync(),
    'outputDigest': target.existsSync()
        ? PipelineBundle.decode(target.readAsBytesSync()).version
        : null,
    'jobIds': commands.jobs.map((j) => j.id).toList(),
  };
}

void main() {
  final receipts = <String, Object?>{};
  tearDownAll(() async {
    final destination = Platform.environment['GAME_FAILURE_RECEIPT_PATH'];
    if (destination == null || receipts.length != 6) return;
    final file = File(destination);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'schemaVersion': 1, 'cases': receipts}),
    );
  });
  void record(
    String name,
    String actual,
    String recovery,
    Map<String, Object?> before,
    Map<String, Object?> after,
    Map<String, int> baseline,
    Map<String, int> cleaned,
  ) {
    expect(after, before);
    expect(cleaned, baseline);
    receipts[name] = {
      'status': 'passed',
      'actualStatus': actual,
      'before': before,
      'after': after,
      'cleanupCounters': {'before': baseline, 'after': cleaned},
      'recovery': {'action': recovery, 'status': 'passed'},
      'execution': {
        'kind': 'pure',
        'exitCode': 0,
        'command':
            'fvm dart --packages=.dart_tool/package_config.json packages/zyren_game_studio/test/failure_receipts_test.dart',
      },
    };
  }

  test(
    'failure receipt prefab.cycle preserves the current authoring document',
    () {
      final fixture = BuildFixture(Directory.systemTemp);
      final original = fixture.document;
      final before = {
        'document': original.encode(),
        'prefabs': original.prefabs.length,
      };
      expect(
        () => original.copyWith(
          prefabs: [
            StudioPrefab(
              id: 'cycle',
              label: 'Cycle',
              version: '1',
              nodes: [
                StudioNode(
                  id: 'child',
                  label: 'Child',
                  kind: StudioNodeKind.prefab,
                  prefabId: 'cycle',
                ),
              ],
            ),
          ],
        ),
        throwsArgumentError,
      );
      final after = {
        'document': original.encode(),
        'prefabs': original.prefabs.length,
      };
      final valid = StudioDocument.decode(original.encode());
      expect(valid.encode(), original.encode());
      record(
        'prefab.cycle',
        'rejected',
        'reload_acyclic_document',
        before,
        after,
        {'retainedPrefabs': original.prefabs.length},
        {'retainedPrefabs': valid.prefabs.length},
      );
    },
  );

  test(
    'failure receipt editor.conflict rejects a stale reviewed edit without undo mutation',
    () async {
      final document = StudioDocument(
        id: 'edit',
        title: 'Edit',
        nodes: [StudioNode(id: 'actor', label: 'Actor')],
      );
      final scene = StudioScene(document, includeEnvironment: false);
      final engine = await SceneEngine.create(
        scene: scene.scene,
        camera: scene.camera,
        rendererFactory: () async => CommandRenderer(),
        plugins: [scene.tools, scene.engineering],
      );
      addTearDown(engine.dispose);
      final commands = StudioCommands(
        scene: scene,
        sessionId: 'edit-session',
        isAllowed: (_) => true,
        isAvailable: () => true,
      );
      final reviewed = commands.revision;
      scene.edit(
        () => scene.tools.transform(
          scene.objects['actor']!,
          position: const Vec3(2, 0, 0),
        ),
      );
      Map<String, Object?> identity() => {
        'document': scene.capture().encode(),
        'revision': commands.revision,
        'historyUndo': scene.canUndo,
        'historyRedo': scene.canRedo,
        'receipts': commands.inspect()['receiptCount'],
      };
      final before = identity();
      expect(
        () => commands.execute(
          commandId: 'stale',
          expectedRevision: reviewed,
          kind: StudioCommandKind.transform,
          targetId: 'actor',
          position: const Vec3(9, 0, 0),
        ),
        throwsA(
          isA<StudioCommandException>().having(
            (e) => e.code,
            'code',
            StudioCommandFailure.stale,
          ),
        ),
      );
      final after = identity();
      commands.execute(
        commandId: 'fresh',
        expectedRevision: commands.revision,
        kind: StudioCommandKind.transform,
        targetId: 'actor',
        position: const Vec3(3, 0, 0),
      );
      expect(scene.objects['actor']!.position.x, 3);
      commands.dispose();
      record(
        'editor.conflict',
        'rejected',
        'refresh_revision_and_edit',
        before,
        after,
        {'activeCommandSessions': 0},
        {
          'activeCommandSessions': commands.inspect()['available'] == true
              ? 1
              : 0,
        },
      );
    },
  );

  test(
    'failure receipt tools.denied rejects missing build scope before publication',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'game-failure-denied-',
      );
      final f = BuildFixture(directory), commands = f.commands();
      final registry = AgentRegistry(grantedScopes: {'game.read'});
      final provider = GameStudioAgentProvider(
        commands: commands,
        instanceId: 'tools',
      );
      final registration = provider.attach(registry);
      try {
        final inspected = await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'inspect',
        );
        final before = f.identity(commands);
        final denied = await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'build',
          expectedRevision: provider.revision,
          idempotencyKey: 'denied',
          arguments: {
            'documentRevision': 1,
            'registrationId': inspected.data['registrationId'],
          },
        );
        expect(denied.status, AgentStatus.denied);
        expect(commands.jobs, isEmpty);
        expect(f.target.existsSync(), isFalse);
        final after = f.identity(commands);
        registration.dispose();
        await commands.close();

        final recovered = f.commands();
        final granted = AgentRegistry(
          grantedScopes: {'game.read', 'game.build'},
        );
        final freshProvider = GameStudioAgentProvider(
          commands: recovered,
          instanceId: 'recovery',
        );
        final freshRegistration = freshProvider.attach(granted);
        try {
          final inspected = await granted.call(
            providerId: freshProvider.id,
            instanceId: freshProvider.instanceId,
            tool: 'inspect',
          );
          final build = await granted.call(
            providerId: freshProvider.id,
            instanceId: freshProvider.instanceId,
            tool: 'build',
            expectedRevision: freshProvider.revision,
            idempotencyKey: 'recovery',
            arguments: {
              'documentRevision': 1,
              'registrationId': inspected.data['registrationId'],
            },
          );
          expect(build.status, AgentStatus.ok);
          await recovered.jobs.single.done;
          expect(recovered.jobs.single.state, PipelineBuildState.succeeded);
        } finally {
          freshRegistration.dispose();
          await recovered.close();
          granted.dispose();
        }
        record(
          'tools.denied',
          'denied',
          'retry_with_build_scope',
          before,
          after,
          {'activeJobs': 0, 'providers': 0},
          {
            'activeJobs': commands.activeJobs.length,
            'providers': (registry.discover()['providers'] as List).length,
          },
        );
      } finally {
        registration.dispose();
        await commands.close();

        registry.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'failure receipt tools.retry keeps the completed publication and exact job identity',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'game-failure-retry-',
      );
      final f = BuildFixture(directory), commands = f.commands();
      final registry = AgentRegistry(
        grantedScopes: {'game.read', 'game.build'},
      );
      final provider = GameStudioAgentProvider(
            commands: commands,
            instanceId: 'tools',
          ),
          registration = provider.attach(registry);
      try {
        final inspected = await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'inspect',
        );
        final revision = provider.revision,
            args = {
              'documentRevision': 1,
              'registrationId': inspected.data['registrationId'],
            };
        Future<AgentResult> build(String id, int version) => registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'build',
          expectedRevision: version,
          idempotencyKey: id,
          arguments: args,
        );
        final first = await build('same', revision);
        expect(first.status, AgentStatus.ok);
        await commands.jobs.single.done;
        final before = f.identity(commands),
            again = await build('same', revision);
        expect(again.status, AgentStatus.ok);
        expect(again.data, first.data);
        expect(commands.jobs, hasLength(1));
        expect(f.publications, 1);
        final after = f.identity(commands);
        expect(
          (await build('fresh', provider.revision)).status,
          AgentStatus.ok,
        );
        await commands.jobs.last.done;
        expect(f.publications, 2);
        registration.dispose();
        await commands.close();

        record(
          'tools.retry',
          'deduplicated',
          'retry_with_fresh_request',
          before,
          after,
          {'activeJobs': 0, 'providers': 0},
          {
            'activeJobs': commands.activeJobs.length,
            'providers': (registry.discover()['providers'] as List).length,
          },
        );
      } finally {
        registration.dispose();
        await commands.close();

        registry.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  for (final detach in [false, true]) {
    test(
      'failure receipt ${detach ? 'tools.dispose' : 'tools.cancel'} prevents pending publication and allows recovery',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'game-failure-cancel-',
        );
        final f = BuildFixture(directory)..hold = true;
        final commands = f.commands(),
            registry = AgentRegistry(
              grantedScopes: {'game.read', 'game.build'},
            );
        final provider = GameStudioAgentProvider(
              commands: commands,
              instanceId: 'tools',
            ),
            registration = provider.attach(registry);
        try {
          final inspected = await registry.call(
            providerId: provider.id,
            instanceId: provider.instanceId,
            tool: 'inspect',
          );
          final result = await registry.call(
            providerId: provider.id,
            instanceId: provider.instanceId,
            tool: 'build',
            expectedRevision: provider.revision,
            idempotencyKey: 'pending',
            arguments: {
              'documentRevision': 1,
              'registrationId': inspected.data['registrationId'],
            },
          );
          expect(result.status, AgentStatus.ok);
          await f.ready.future;
          final job = commands.jobs.single;
          Map<String, Object?> protectedIdentity() => {
            ...f.identity(commands)..remove('jobIds'),
            'jobId': job.id,
          };
          final before = protectedIdentity();
          if (detach) {
            registration.dispose();
          } else {
            final cancel = await registry.call(
              providerId: provider.id,
              instanceId: provider.instanceId,
              tool: 'cancel',
              expectedRevision: provider.revision,
              idempotencyKey: 'cancel',
              arguments: {
                'jobId': commands.jobs.single.id,
                'registrationId': inspected.data['registrationId'],
              },
            );
            expect(cancel.status, AgentStatus.ok);
            expect(cancel.data['changed'], isTrue);
          }
          f.release.complete();
          await job.done;
          expect(job.state, PipelineBuildState.cancelled);
          expect(f.publications, 0);
          expect(f.target.existsSync(), isFalse);
          final after = protectedIdentity();
          registration.dispose();
          await commands.close();

          f.hold = false;
          final recovered = f.commands();
          final retry =
              recovered.startBuild(expectedRevision: 1, requestId: 'recovery')
                  as StartedBuildResult;
          await retry.job.done;
          expect(retry.job.state, PipelineBuildState.succeeded);
          expect(f.publications, 1);
          await recovered.close();
          record(
            detach ? 'tools.dispose' : 'tools.cancel',
            'cancelled',
            'reattach_and_publish',
            before,
            after,
            {'activeJobs': 0, 'providers': 0},
            {
              'activeJobs': commands.activeJobs.length,
              'providers': (registry.discover()['providers'] as List).length,
            },
          );
        } finally {
          if (!f.release.isCompleted) f.release.complete();
          registration.dispose();
          await commands.close();

          registry.dispose();
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
