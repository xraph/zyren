import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren_agents/zyren_agents.dart';

const anyObject = <String, Object?>{'type': 'object'};

class CounterProvider extends AgentProvider {
  int count = 0;
  Completer<void>? gate;
  @override
  String get id => 'test.counter';
  @override
  String get version => '1';
  @override
  String get instanceId => 'main';
  @override
  int get revision => count;
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'read',
      description: 'Read counter.',
      inputSchema: anyObject,
      outputSchema: anyObject,
    ),
    AgentTool(
      name: 'increment',
      description: 'Increment counter.',
      readOnly: false,
      requiredScopes: {'counter.write'},
      inputSchema: {
        'type': 'object',
        'properties': {
          'amount': {'type': 'integer', 'minimum': 1, 'maximum': 10},
        },
        'required': ['amount'],
        'additionalProperties': false,
      },
      outputSchema: anyObject,
    ),
  ];
  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    await gate?.future;
    context.checkCancelled();
    if (tool == 'increment') count += arguments['amount'] as int;
    return AgentResult(
      AgentStatus.ok,
      data: {'count': count},
      revision: revision,
      affectedIds: tool == 'increment' ? ['counter'] : [],
    );
  }
}

void main() {
  late CounterProvider provider;
  late AgentRegistry registry;
  setUp(() {
    provider = CounterProvider();
    registry = AgentRegistry(grantedScopes: {'counter.write'});
  });
  tearDown(() => registry.dispose());
  Future<AgentResult> increment({
    String key = 'one',
    int revision = 0,
    Map<String, Object?> arguments = const {'amount': 1},
  }) => registry.call(
    providerId: provider.id,
    instanceId: provider.instanceId,
    tool: 'increment',
    arguments: arguments,
    expectedRevision: revision,
    idempotencyKey: key,
  );
  test('discovery, real read conformance, and disposal', () async {
    final lease = registry.register(provider);
    expect(
      (registry.discover()['providers'] as List).single['tools'],
      hasLength(2),
    );
    expect(
      await AgentConformance.checkRead(
        registry: registry,
        provider: provider,
        tool: 'read',
      ),
      isEmpty,
    );
    lease.dispose();
    expect(registry.discover()['providers'], isEmpty);
    expect((await increment()).status, AgentStatus.unavailable);
  });
  test('host scopes deny actions without invoking provider', () async {
    registry.dispose();
    registry = AgentRegistry();
    registry.register(provider);
    expect((await increment()).status, AgentStatus.denied);
    expect(provider.count, 0);
  });
  test('schema rejects unknown, missing, wrong type and bounds', () async {
    registry.register(provider);
    for (final arguments in <Map<String, Object?>>[
      {},
      {'amount': 0},
      {'amount': 11},
      {'amount': '1'},
      {'amount': 1, 'scope': 'counter.write'},
    ]) {
      expect(
        (await increment(arguments: arguments)).status,
        AgentStatus.invalid,
      );
    }
    expect(provider.count, 0);
    expect(
      () => AgentTool(
        name: 'bad',
        description: 'Bad schema',
        inputSchema: {'type': 'string', 'pattern': '.'},
        outputSchema: anyObject,
      ),
      throwsArgumentError,
    );
  });
  test('mutation revision, retry ledger and key conflict', () async {
    registry.register(provider);
    expect((await increment()).revision, 1);
    expect((await increment()).revision, 1);
    expect(provider.count, 1);
    expect(
      (await increment(arguments: {'amount': 2})).status,
      AgentStatus.invalid,
    );
    expect((await increment(key: 'two')).status, AgentStatus.stale);
    expect((await increment(key: 'two', revision: 1)).revision, 2);
  });
  test(
    'simultaneous retries apply once and another action sees busy',
    () async {
      registry.register(provider);
      provider.gate = Completer();
      final first = increment(), retry = increment();
      expect((await increment(key: 'two')).status, AgentStatus.unavailable);
      provider.gate!.complete();
      expect((await first).status, AgentStatus.ok);
      expect((await retry).status, AgentStatus.ok);
      expect(provider.count, 1);
    },
  );
  test('cancelled and detached jobs never commit', () async {
    final lease = registry.register(provider);
    provider.gate = Completer();
    final call = increment();
    lease.dispose();
    provider.gate!.complete();
    expect((await call).status, AgentStatus.cancelled);
    expect(provider.count, 0);
  });
  test(
    'shared cancellation tokens retain every pending call until detach',
    () async {
      final lease = registry.register(provider);
      final token = AgentCancellation();
      final firstGate = Completer<void>(), secondGate = Completer<void>();
      provider.gate = firstGate;
      final first = registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'read',
        cancellation: token,
      );
      provider.gate = secondGate;
      final second = registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'read',
        cancellation: token,
      );
      firstGate.complete();
      expect((await first).status, AgentStatus.ok);
      lease.dispose();
      expect(token.isCancelled, isTrue);
      secondGate.complete();
      expect((await second).status, AgentStatus.cancelled);
    },
  );

  test(
    'retry budget rejects new writes without evicting old results',
    () async {
      registry.dispose();
      registry = AgentRegistry(
        grantedScopes: {'counter.write'},
        maxRetryEntries: 1,
      );
      registry.register(provider);
      await increment();
      expect(
        (await increment(key: 'two', revision: 1)).status,
        AgentStatus.unavailable,
      );
      expect((await increment()).status, AgentStatus.ok);
      expect(provider.count, 1);
    },
  );
  test(
    'async read reports stale state and pre-cancelled read is explicit',
    () async {
      registry.register(provider);
      provider.gate = Completer();
      final read = registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'read',
      );
      provider.count++;
      provider.gate!.complete();
      expect((await read).status, AgentStatus.stale);
      final token = AgentCancellation()..cancel();
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'read',
          cancellation: token,
        )).status,
        AgentStatus.cancelled,
      );
    },
  );
}
