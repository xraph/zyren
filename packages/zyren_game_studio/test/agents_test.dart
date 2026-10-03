import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_game_studio/agents.dart';
import 'package:zyren_game_studio/export.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

void main() {
  test(
    'registration identity rejects reviewed calls after provider replacement',
    () async {
      final authoring = createGameDevelopmentAuthoring();
      final doc = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'tools').document;
      var publishes = 0;
      GameBuildCommands commands() => GameBuildCommands(
        compiler: GameProjectCompiler(
          registry: authoring.registry,
          assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
        ),
        documents: () => [doc],
        revision: () => 1,
        startupLevel: () => 'main',
        profile: () => GameLevelAuthoring(authoring).profile(doc),
        allows: (_) => true,
        isAvailable: () => true,
        outputLabel: 'game.zygame',
        publish: (_, token, check) async {
          check();
          publishes++;
        },
      );
      final registry = AgentRegistry(grantedScopes: {'game.build'});
      final first = GameStudioAgentProvider(
        commands: commands(),
        instanceId: 'tools',
      );
      final lease = first.attach(registry);
      final reviewed = await registry.call(
        providerId: first.id,
        instanceId: first.instanceId,
        tool: 'inspect',
      );
      final oldId = reviewed.data['registrationId'];
      lease.dispose();
      await first.commands.close();
      final next = GameStudioAgentProvider(
        commands: commands(),
        instanceId: 'tools',
      );
      final secondLease = next.attach(registry);
      final stale = await registry.call(
        providerId: next.id,
        instanceId: next.instanceId,
        tool: 'build',
        expectedRevision: next.revision,
        idempotencyKey: 'approved-before-replace',
        arguments: {'documentRevision': 1, 'registrationId': oldId},
      );
      expect(stale.status, AgentStatus.stale);
      expect(next.commands.jobs, isEmpty);
      final current = await registry.call(
        providerId: next.id,
        instanceId: next.instanceId,
        tool: 'inspect',
      );
      final args = {
        'documentRevision': 1,
        'registrationId': current.data['registrationId'],
      };
      final denied = await registry.call(
        providerId: next.id,
        instanceId: next.instanceId,
        tool: 'build',
        expectedRevision: next.revision,
        idempotencyKey: 'read-only',
        arguments: args,
        readOnlyOnly: true,
      );
      expect(denied.status, AgentStatus.denied);
      expect(next.commands.jobs, isEmpty);
      final started = await registry.call(
        providerId: next.id,
        instanceId: next.instanceId,
        tool: 'build',
        expectedRevision: next.revision,
        idempotencyKey: 'current',
        arguments: args,
      );
      expect(started.status, AgentStatus.ok, reason: started.message);
      await next.commands.jobs.single.done;
      expect(publishes, 1);
      secondLease.dispose();
      await next.commands.close();
      registry.dispose();
    },
  );
  test('agent disposal cancels publication before its commit', () async {
    final authoring = createGameDevelopmentAuthoring();
    final doc = GameTemplate(
      GameTemplateKind.vehiclePlayground,
      authoring,
    ).create(projectId: 'tools').document;
    final ready = Completer<void>(), release = Completer<void>();
    var published = false;
    final commands = GameBuildCommands(
      compiler: GameProjectCompiler(
        registry: authoring.registry,
        assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
      ),
      documents: () => [doc],
      revision: () => 1,
      startupLevel: () => 'main',
      profile: () => GameLevelAuthoring(authoring).profile(doc),
      allows: (_) => true,
      isAvailable: () => true,
      outputLabel: 'game.zygame',
      publish: (_, token, check) async {
        ready.complete();
        await release.future;
        check();
        published = true;
      },
    );
    final registry = AgentRegistry(grantedScopes: {'game.build'});
    final provider = GameStudioAgentProvider(
      commands: commands,
      instanceId: 'tools',
    );
    final lease = provider.attach(registry);
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
      idempotencyKey: 'dispose',
      arguments: {
        'documentRevision': 1,
        'registrationId': inspected.data['registrationId'],
      },
    );
    expect(result.status, AgentStatus.ok, reason: result.message);
    await ready.future;
    lease.dispose();
    release.complete();
    await commands.close();
    expect(published, isFalse);
    registry.dispose();
  });
}
