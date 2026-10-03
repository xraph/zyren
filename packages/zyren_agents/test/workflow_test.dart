import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_agents/workflow.dart';
import 'registry_test.dart' show CounterProvider;

class ScriptModel implements AgentModel {
  final FutureOr<AgentReply> Function(int, List<Map<String, Object?>>) reply;
  int calls = 0;
  ScriptModel(this.reply);
  @override
  Future<AgentReply> complete({
    required List<Map<String, Object?>> messages,
    required List<Map<String, Object?>> tools,
    required AgentCancellation cancellation,
  }) async => reply(calls++, messages);
  @override
  void close() {}
}

AgentToolCall increment(
  AgentRegistry registry, {
  int? revision,
  int? registration,
}) {
  final provider = (registry.discover()['providers'] as List).first as Map;
  return AgentToolCall('call-1', 'call_tool', {
    'providerId': provider['providerId'],
    'instanceId': provider['instanceId'],
    'tool': 'increment',
    'arguments': {'amount': 1},
    'expectedRevision': revision ?? provider['revision'],
    'registrationId': registration ?? provider['registrationId'],
  });
}

void main() {
  late CounterProvider provider;
  late AgentRegistry registry;
  setUp(() {
    provider = CounterProvider();
    registry = AgentRegistry(grantedScopes: {'counter.write'});
    registry.register(provider);
  });
  tearDown(() => registry.dispose());
  test(
    'discovers, describes, calls and continues using actual tool results',
    () async {
      final approvals = <AgentApproval>[];
      final model = ScriptModel((step, messages) {
        if (step == 0) {
          return AgentReply(calls: [AgentToolCall('list', 'list_plugins', {})]);
        }
        final result =
            jsonDecode(messages[messages.length - 2]['content'] as String)
                as Map;
        if (step == 1) {
          expect((result['providers'] as List).single['toolCount'], 2);
          return AgentReply(
            calls: [
              AgentToolCall('describe', 'describe_plugin', {
                'providerId': provider.id,
                'instanceId': provider.instanceId,
              }),
            ],
          );
        }
        if (step == 2) {
          expect((result['tools'] as List).length, 2);
          return AgentReply(calls: [increment(registry)]);
        }
        expect(result['status'], 'ok');
        expect(result['data']['count'], 1);
        return AgentReply(text: 'Counter incremented.');
      });
      final workflow = AgentWorkflow(
        registry: registry,
        model: model,
        context: () => {},
        approve: (a) async {
          approvals.add(a);
          return true;
        },
      );
      expect(await workflow.run('Increment once'), AgentRunState.complete);
      expect(provider.count, 1);
      expect(approvals.single.tool, 'increment');
    },
  );
  test('declined edits are not executed', () async {
    final model = ScriptModel(
      (step, _) => step == 0
          ? AgentReply(calls: [increment(registry)])
          : AgentReply(text: 'Declined.'),
    );
    final run = AgentWorkflow(
      registry: registry,
      model: model,
      context: () => {},
      approve: (_) async => false,
    );
    await run.run('Increment');
    expect(provider.count, 0);
  });
  test('scene changes while approval is open reject stale commands', () async {
    final results = <AgentWorkflowEvent>[];
    final model = ScriptModel(
      (step, _) =>
          step == 0 ? AgentReply(calls: [increment(registry)]) : AgentReply(),
    );
    final run = AgentWorkflow(
      registry: registry,
      model: model,
      context: () => {},
      approve: (_) async {
        provider.count = 2;
        return true;
      },
      onEvent: results.add,
    );
    await run.run('Increment');
    expect(provider.count, 2);
    expect(
      results.where((e) => e.kind == 'tool_result').single.data['status'],
      'stale',
    );
  });
  test(
    'reattached provider with same revision cannot consume old approval',
    () async {
      final isolated = AgentRegistry(grantedScopes: {'counter.write'});
      final first = CounterProvider();
      final handle = isolated.register(first);
      final second = CounterProvider();
      final results = <AgentWorkflowEvent>[];
      final model = ScriptModel(
        (step, _) =>
            step == 0 ? AgentReply(calls: [increment(isolated)]) : AgentReply(),
      );
      final run = AgentWorkflow(
        registry: isolated,
        model: model,
        context: () => {},
        approve: (_) async {
          handle.dispose();
          isolated.register(second);
          return true;
        },
        onEvent: results.add,
      );
      await run.run('Increment');
      expect(second.count, 0);
      expect(
        results.where((e) => e.kind == 'tool_result').single.data['status'],
        'stale',
      );
      isolated.dispose();
    },
  );
  test('cancellation releases pending approval without executing', () async {
    final waiting = Completer<void>();
    final decision = Completer<bool>();
    final model = ScriptModel(
      (_, _) => AgentReply(calls: [increment(registry)]),
    );
    final run = AgentWorkflow(
      registry: registry,
      model: model,
      context: () => {},
      approve: (_) {
        waiting.complete();
        return decision.future;
      },
    );
    final result = run.run('Increment');
    await waiting.future;
    run.stop();
    expect(await result, AgentRunState.stopped);
    expect(provider.count, 0);
    decision.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(provider.count, 0);
  });
  test('ungranted scopes never open review or execute', () async {
    final isolated = AgentRegistry();
    isolated.register(provider);
    final model = ScriptModel(
      (step, _) =>
          step == 0 ? AgentReply(calls: [increment(isolated)]) : AgentReply(),
    );
    final run = AgentWorkflow(
      registry: isolated,
      model: model,
      context: () => {},
      approve: (_) async => fail('No grant'),
    );
    await run.run('Increment');
    expect(provider.count, 0);
    isolated.dispose();
  });
  test('step budget stops a looping model', () async {
    final model = ScriptModel(
      (step, _) =>
          AgentReply(calls: [AgentToolCall('read-$step', 'list_plugins', {})]),
    );
    final run = AgentWorkflow(
      registry: registry,
      model: model,
      context: () => {},
      approve: (_) async => false,
      maxSteps: 3,
    );
    expect(await run.run('Inspect'), AgentRunState.limitReached);
    expect(model.calls, 3);
  });
  test('new plugins appear without recreating the workflow', () async {
    final results = <AgentWorkflowEvent>[];
    final model = ScriptModel(
      (step, _) => step.isEven
          ? AgentReply(calls: [AgentToolCall('list-$step', 'list_plugins', {})])
          : AgentReply(),
    );
    final run = AgentWorkflow(
      registry: registry,
      model: model,
      context: () => {},
      approve: (_) async => false,
      onEvent: results.add,
    );
    await run.run('Inspect');
    registry.register(FutureMorphProvider());
    await run.run('Inspect again');
    final data = results.where((e) => e.kind == 'tool_result').last.data;
    expect(
      (data['providers'] as List).any(
        (p) => p['providerId'] == 'test.future-morph',
      ),
      isTrue,
    );
  });
}

class FutureMorphProvider extends CounterProvider {
  @override
  String get id => 'test.future-morph';
}
