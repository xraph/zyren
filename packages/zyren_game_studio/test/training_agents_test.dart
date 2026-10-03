import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_game_studio/training.dart';
import 'package:zyren_game_studio/training_agents.dart';
import 'training_support.dart';

void main() {
  test(
    'independent training scopes, stale revisions and retry keys share one runner',
    () async {
      final root = await Directory.systemTemp.createTemp('training-agent-');
      addTearDown(() => root.delete(recursive: true));
      final runner = TrainingRunner();
      addTearDown(runner.close);
      final provider = TrainingAgentProvider(
        runner: runner,
        requests: {'smoke': await processFixture(root, 'complete')},
        currentRevision: () => 7,
        permits: (_) => true,
        instanceId: 'project',
      );
      final registry = AgentRegistry(
        grantedScopes: {'training.inspect', 'training.start'},
      );
      final lease = registry.register(provider);
      addTearDown(lease.dispose);
      Future<AgentResult> call(
        String tool, {
        int? revision,
        String? key,
        Map<String, Object?> args = const {},
      }) => registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: tool,
        expectedRevision: revision,
        idempotencyKey: key,
        arguments: args,
      );
      expect((await call('inspect')).status, AgentStatus.ok);
      expect(runner.runs, isEmpty);
      expect(
        (await call(
          'start',
          revision: 6,
          key: 'stale',
          args: {'profile': 'smoke'},
        )).status,
        AgentStatus.stale,
      );
      expect(
        (await call(
          'stop',
          revision: 7,
          key: 'denied',
          args: {'run': 0},
        )).status,
        AgentStatus.denied,
      );
      final started = await call(
        'start',
        revision: 7,
        key: 'same',
        args: {'profile': 'smoke'},
      );
      expect(started.status, AgentStatus.ok);
      final duplicate = await call(
        'start',
        revision: 7,
        key: 'same',
        args: {'profile': 'smoke'},
      );
      expect(duplicate.status, AgentStatus.ok);
      expect(runner.runs.length, 1);
      await runner.runs.single.done;
      expect(runner.runs.single.state, TrainingRunState.completed);
    },
  );
}
