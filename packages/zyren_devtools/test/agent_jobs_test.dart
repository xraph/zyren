import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/agents.dart';
import 'package:zyren_devtools/zyren_devtools.dart';

class JobProvider extends AgentProvider {
  final gate = Completer<void>();
  @override
  String get id => 'test.job';
  @override
  String get instanceId => 'main';
  @override
  String get version => '1';
  @override
  int get revision => 0;
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'run',
      description: 'Wait for fixture.',
      inputSchema: const {'type': 'object'},
      outputSchema: const {'type': 'object'},
    ),
  ];
  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    context.reportProgress(.25, 'Started');
    await gate.future;
    context.checkCancelled();
    context.reportProgress(1, 'Done');
    return AgentResult(
      AgentStatus.ok,
      data: {'done': true},
      revision: revision,
    );
  }
}

void main() {
  test(
    'job tools expose progress, exact starts, cancellation and bounded change cursors',
    () async {
      final registry = AgentRegistry();
      final provider = JobProvider();
      registry.register(provider);
      final bridge = AgentDevtoolsBridge(registry);
      final args = {
        'jobId': 'first',
        'providerId': provider.id,
        'instanceId': provider.instanceId,
        'tool': 'run',
        'readOnly': true,
      };
      final started = await bridge.call('agent_job_start', args);
      expect((started['agentJob'] as Map)['state'], 'running');
      expect(
        (await bridge.call('agent_job_start', args))['agentJob'],
        started['agentJob'],
      );
      await expectLater(
        bridge.call('agent_job_start', {...args, 'tool': 'different'}),
        throwsA(isA<DiagnosticException>()),
      );
      final status =
          (await bridge.call('agent_job_status', {
                'jobId': 'first',
              }))['agentJob']
              as Map;
      expect((status['progress'] as Map)['fraction'], .25);
      await bridge.call('agent_job_cancel', {'jobId': 'first'});
      provider.gate.complete();
      await Future<void>.delayed(Duration.zero);
      final cancelled =
          (await bridge.call('agent_job_status', {
                'jobId': 'first',
              }))['agentJob']
              as Map;
      expect(cancelled['state'], 'complete');
      expect((cancelled['result'] as Map)['status'], 'cancelled');
      final changes =
          (await bridge.call('agent_changes', {}))['agentChanges'] as Map;
      expect(changes['gap'], isFalse);
      expect(
        (changes['events'] as List).map((e) => e['kind']),
        contains('job-completed'),
      );
      expect(
        ((await bridge.call('agent_changes', {
              'after': changes['nextCursor'],
            }))['agentChanges']
            as Map)['events'],
        isEmpty,
      );
      await bridge.call('agent_job_release', {'jobId': 'first'});
      await expectLater(
        bridge.call('agent_job_status', {'jobId': 'first'}),
        throwsA(isA<DiagnosticException>()),
      );
      bridge.dispose();
      registry.dispose();
    },
  );
  test(
    'closing bridge requests cancellation without claiming premature completion',
    () async {
      final registry = AgentRegistry();
      final provider = JobProvider();
      registry.register(provider);
      final bridge = AgentDevtoolsBridge(registry);
      await bridge.call('agent_job_start', {
        'jobId': 'close',
        'providerId': provider.id,
        'instanceId': 'main',
        'tool': 'run',
        'readOnly': true,
      });
      bridge.dispose();
      provider.gate.complete();
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        bridge.call('agent_job_status', {'jobId': 'close'}),
        throwsA(isA<DiagnosticException>()),
      );
      registry.dispose();
    },
  );
}
