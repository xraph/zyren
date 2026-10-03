import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/agents.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/agents.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_physics/zyren_physics.dart';
import '../../zyren_game_native/test/support/character_fixture.dart';
import 'policy_test.dart' show ProbeSensor, ProbeEncoder;

void main() {
  test(
    'native teams deliver historical perception with delay and reject opponent/removal',
    () async {
      final f = await GameCharacterFixture.create();
      addTearDown(f.close);
      final entities = f.simulation.session.entities,
          a = f.controller.actor,
          b = entities.spawn('ally'),
          enemy = entities.spawn('enemy'),
          target = entities.spawn('target');
      final ally = f.world.createBody(
        kind: BodyKind.fixed,
        pose: PhysicsPose(position: const Vec3(1, .81, 0)),
      );
      final opponent = f.world.createBody(
        kind: BodyKind.fixed,
        pose: PhysicsPose(position: const Vec3(6, .81, 0)),
      );
      final seen = f.world.createBody(
        kind: BodyKind.fixed,
        pose: PhysicsPose(position: const Vec3(0, .81, -2)),
      );
      final metadata = {
        seen.addCollider(const SphereShape(.1)).id: SensorCollider(
          SensorMaterial.opaque,
          entity: target,
        ),
      };
      BrainIdentity identity(GameEntityHandle h) => BrainIdentity(
        episodeId: 'teams',
        entity: h,
        modelHash: 'script-probe',
      );
      final team =
          GameTeam(id: 'allies', episodeId: 'teams', entities: entities)
            ..join(identity(a))
            ..join(identity(b));
      final enemies = GameTeam(
        id: 'opponents',
        episodeId: 'teams',
        entities: entities,
      )..join(identity(enemy));
      final channel = TeamChannel(
        teams: [team, enemies],
        profile: CommunicationProfile(range: 2, delayTicks: 2, ttlTicks: 12),
      );
      final profile = SensorProfile(range: 10, maxEntities: 4);
      final assembler = ObservationAssembler(
        registry: SensorRegistry()..register(VisionSensor(profile)),
        profile: profile,
      );
      SensorSnapshot snapshot() => SensorSnapshot.fromSimulation(
        episodeId: 'teams',
        worldRevision: 1,
        simulation: f.simulation,
        bindings: {a: f.body, b: ally, enemy: opponent, target: seen},
        colliders: metadata,
        currentRevision: () => 1,
        geometryLoaded: (_, _) => true,
      );
      f.step();
      final captured = snapshot();
      channel.capture(captured);
      final observation = assembler.build(captured, a);
      channel.observe(observation);
      expect(
        channel.send(
          id: 'seen',
          sender: a,
          recipient: b,
          target: target,
          tick: captured.tick,
        ),
        true,
      );
      expect(
        channel.send(
          id: 'enemy',
          sender: a,
          recipient: enemy,
          target: target,
          tick: captured.tick,
        ),
        false,
      );
      f.step();
      expect(channel.receive(b, tick: f.simulation.session.tick), isEmpty);
      seen.teleport(PhysicsPose(position: const Vec3(3, .81, -8)));
      f.step();
      final memory = BeliefStore(identity: identity(b));
      expect(channel.deliverTo(memory, tick: f.simulation.session.tick), 1);
      expect(
        memory.atTick(f.simulation.session.tick).single.position,
        observation.entities
            .whereType<ObservedEntity>()
            .firstWhere((e) => e.handle == target)
            .localPosition,
      );
      expect(memory.atTick(f.simulation.session.tick).single.positionFrame, a);
      expect(
        memory.atTick(f.simulation.session.tick).single.observedTick,
        captured.tick,
      );
      seen.teleport(PhysicsPose(position: const Vec3(0, .81, -2)));
      f.step();
      final current = snapshot();
      channel.capture(current);
      channel.observe(assembler.build(current, a));
      expect(
        channel.send(
          id: 'removed',
          sender: a,
          recipient: b,
          target: target,
          tick: current.tick,
        ),
        true,
      );
      team.leave(a);
      team.join(identity(a));
      f.step(2);
      expect(channel.receive(b, tick: f.simulation.session.tick), isEmpty);
      team.leave(a);
      entities.despawn(a);
      final replacement = entities.spawn(a.id);
      expect(replacement.generation, greaterThan(a.generation));
      team.join(identity(replacement));
      expect(team.contains(a), false);
    },
  );
  test(
    'real recurrent actors share one native model and isolate state/rewards across join and leave',
    () async {
      final f = await GameCharacterFixture.create();
      addTearDown(f.close);
      final entities = f.simulation.session.entities,
          a = f.controller.actor,
          b = entities.spawn('ally'),
          enemy = entities.spawn('enemy');
      final model = MlModelManifest.decode(
        File('../zyren_ml/test/fixtures/lstm_step.json').readAsStringSync(),
      );
      final ml = MlScheduler(
        cache: MlModelCache(
          resolver: (_) =>
              File('../zyren_ml/test/fixtures/lstm_step.onnx').readAsBytes(),
        ),
        currentTick: () => f.simulation.session.tick,
      );
      final group = PolicyGroup(
        episodeId: 'shared',
        entities: entities,
        ml: ml,
      );
      addTearDown(() async {
        await group.close();
        await ml.close();
      });
      final sensor = ProbeSensor(), registry = SensorRegistry();
      registry.register(sensor);
      final assembler = ObservationAssembler(
        registry: registry,
        profile: SensorProfile(),
        latencyTicks: 2,
      );
      final contract = PolicyContract(
        model: model,
        observation: assembler.spec,
        decoder: ActionDecoder.character(),
        encoder: const ProbeEncoder(),
        latencyTicks: 2,
      );
      BrainIdentity identity(GameEntityHandle h) => BrainIdentity(
        episodeId: 'shared',
        entity: h,
        modelHash: model.sha256,
      );
      final first = group.join(identity(a), contract),
          second = group.join(identity(b), contract);
      group.join(identity(enemy), contract);
      final team =
          GameTeam(id: 'allies', episodeId: 'shared', entities: entities)
            ..join(identity(a))
            ..join(identity(b));
      expect(group.modelCount, 1);
      expect(identical(group.stateFor(a), group.stateFor(b)), false);
      ObservationFrame frame(GameEntityHandle h, List<double> values) {
        sensor.values = values;
        return assembler.build(
          SensorSnapshot(
            episodeId: 'shared',
            tick: f.simulation.session.tick,
            worldRevision: 1,
            entities: [SensorEntity(handle: h, pose: PhysicsPose())],
            colliders: {},
            currentRevision: () => 1,
            geometryLoaded: (_, _) => true,
          ),
          h,
        );
      }

      BrainContext context(PolicyBrain brain) => BrainContext(
        identity: brain.identity,
        tick: f.simulation.session.tick,
        beliefs: [],
        goals: [],
        actionSpec: contract.decoder.spec,
      );
      first.observe(frame(a, [.2, .1, -.3, .4]));
      second.observe(frame(b, [-.7, .9, .2, -.6]));
      final queued = [
        first.request(context(first)),
        second.request(context(second)),
      ];
      final flush = ml.flush();
      final candidates = await Future.wait(queued);
      await flush;
      expect(candidates.every((c) => c != null), true);
      expect(ml.cache.diagnostics.residentModels, 1);
      f.step(2);
      final decision = first.decide(context(first));
      second.decide(context(second));
      expect(first.state.version, 1);
      expect(second.state.version, 1);
      expect(
        first.state.tensors['hidden']!.bytes,
        isNot(second.state.tensors['hidden']!.bytes),
      );
      f.controller.apply(
        contract.decoder.decode(decision.policyAction!)!.character!,
      );
      f.step();
      expect(
        group.creditTeamReward(team, eventId: 'objective', reward: 2),
        true,
      );
      expect(
        group.creditTeamReward(team, eventId: 'objective', reward: 2),
        false,
      );
      expect(group.rewardFor(a), 2);
      expect(group.rewardFor(b), 2);
      expect(group.rewardFor(enemy), 0);
      await group.leave(b);
      team.leave(b);
      entities.despawn(b);
      final joined = entities.spawn(b.id);
      final fresh = group.join(identity(joined), contract);
      team.join(identity(joined));
      expect(fresh.state.version, 0);
      expect(first.state.version, 1);
      expect(identical(fresh.state, second.state), false);
      expect(group.rewardFor(joined), 0);
      expect(group.modelCount, 1);
      expect((await ml.cache.worker.diagnostics()).liveSessions, 1);
      await group.close();
      await ml.close();
      expect((await ml.cache.worker.diagnostics()).liveSessions, 0);
    },
  );
  test(
    'external existing MCP client inspects and controls native policy host with scoped revision checks',
    () async {
      final f = await GameCharacterFixture.create();
      addTearDown(f.close);
      final model = MlModelManifest.decode(
        File('../zyren_ml/test/fixtures/lstm_step.json').readAsStringSync(),
      );
      final linear = MlModelManifest.decode(
        File('../zyren_ml/test/fixtures/linear.json').readAsStringSync(),
      );
      final preparing = Completer<void>(), modelBytes = Completer<void>();
      final ml = MlScheduler(
        cache: MlModelCache(
          resolver: (path) async {
            if (path == linear.modelFile) {
              preparing.complete();
              await modelBytes.future;
            }
            return File('../zyren_ml/test/fixtures/$path').readAsBytes();
          },
        ),
        currentTick: () => f.simulation.session.tick,
      );
      final group = PolicyGroup(
        episodeId: 'mcp',
        entities: f.simulation.session.entities,
        ml: ml,
      );
      addTearDown(() async {
        await group.close();
        await ml.close();
      });
      final actor = f.controller.actor, sensor = ProbeSensor();
      final assembler = ObservationAssembler(
        registry: SensorRegistry()..register(sensor),
        profile: SensorProfile(),
        latencyTicks: 2,
      );
      final contract = PolicyContract(
        model: model,
        observation: assembler.spec,
        decoder: ActionDecoder.character(),
        encoder: const ProbeEncoder(),
        latencyTicks: 2,
      );
      final linearContract = PolicyContract(
        model: linear,
        observation: assembler.spec,
        decoder: ActionDecoder.character(),
        encoder: const ProbeEncoder(),
        latencyTicks: 2,
      );
      group.join(
        BrainIdentity(episodeId: 'mcp', entity: actor, modelHash: model.sha256),
        contract,
      );
      var permit = false;
      final registry = AgentRegistry(
        grantedScopes: {'ai.read', 'ai.control', 'ml.read'},
      );
      addTearDown(registry.dispose);
      registry.register(
        GameAiAgentProvider(
          host: GameAiPolicyHost(
            group: group,
            models: {'lstm': contract, 'linear': linearContract},
            permits: (_) => permit,
            currentRevision: () =>
                group.revision + f.simulation.session.revision,
          ),
          instanceId: 'episode',
        ),
      );
      registry.register(
        MlAgentProvider(
          scheduler: ml,
          models: {'lstm': model},
          currentRevision: () => group.revision,
          instanceId: 'worker',
        ),
      );
      final server = await DevtoolsServer.start(
        SceneDiagnostics(SceneDevtoolsPlugin()),
        agents: registry,
      );
      addTearDown(server.close);
      final process = await Process.start(
        Platform.resolvedExecutable,
        ['run', '../zyren_devtools/bin/zyren.dart', 'mcp'],
        workingDirectory: Directory.current.path,
        environment: {
          'ZYREN_DEVTOOLS_ENDPOINT': server.endpoint.toString(),
          'ZYREN_DEVTOOLS_TOKEN': server.token,
          'ZYREN_AGENT_TOOLS': '1',
        },
      );
      final replies = StreamIterator<String>(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = process.stderr.transform(utf8.decoder).join();
      var id = 0;
      Future<Map<String, dynamic>> request(
        String method, [
        Map<String, Object?> params = const {},
      ]) async {
        final next = ++id;
        process.stdin.writeln(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': next,
            'method': method,
            'params': params,
          }),
        );
        while (await replies.moveNext()) {
          final decoded = jsonDecode(replies.current) as Map<String, dynamic>;
          if (decoded['id'] == next) return decoded;
        }
        throw StateError('MCP process ended: ${await errors}');
      }

      await request('initialize', {
        'protocolVersion': '2025-11-25',
        'capabilities': {},
        'clientInfo': {'name': 'A7-native-probe', 'version': '1'},
      });
      process.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
      );
      Future<Map> tool(String name, Map<String, Object?> args) async {
        final reply = await request('tools/call', {
          'name': name,
          'arguments': args,
        });
        return (reply['result'] as Map)['structuredContent']['agentResult']
            as Map;
      }

      final args = <String, Object?>{
        'providerId': 'zyren_game_ai',
        'instanceId': 'episode',
        'tool': 'inspect',
        'arguments': {'actorId': actor.id, 'generation': actor.generation},
      };
      expect((await tool('agent_query', args))['status'], 'ok');
      expect(
        (await tool('agent_query', {
          'providerId': 'zyren_ml',
          'instanceId': 'worker',
          'tool': 'inspect',
        }))['status'],
        'ok',
      );
      Map<String, Object?> command(
        String operation,
        String key, {
        int? revision,
      }) => {
        ...args,
        'tool': operation,
        'arguments': {
          'actorId': actor.id,
          'generation': actor.generation,
          if (operation == 'select_model') 'modelId': 'lstm',
        },
        'expectedRevision':
            revision ?? group.revision + f.simulation.session.revision,
        'idempotencyKey': key,
      };
      expect(
        (await tool('agent_command', command('reset', 'denied')))['status'],
        'denied',
      );
      permit = true;
      expect(
        (await tool(
          'agent_command',
          command('reset', 'stale', revision: 0),
        ))['status'],
        'stale',
      );
      expect(
        (await tool('agent_command', command('reset', 'reset')))['status'],
        'ok',
      );
      expect(
        (await tool(
          'agent_command',
          command('select_model', 'select'),
        ))['status'],
        'ok',
      );
      expect(ml.cache.diagnostics.residentModels, 1);
      expect(group.brainFor(actor)!.identity.modelHash, model.sha256);
      Future<Map> job(String name, Map<String, Object?> arguments) async {
        final response = await request('tools/call', {
          'name': name,
          'arguments': arguments,
        });
        return (response['result'] as Map)['structuredContent']['agentJob']
            as Map;
      }

      final start = {
        ...command('select_model', 'cancelled-selection'),
        'jobId': 'cancelled',
        'readOnly': false,
        'arguments': {
          'actorId': actor.id,
          'generation': actor.generation,
          'modelId': 'linear',
        },
      };
      expect((await job('agent_job_start', start))['state'], 'running');
      await preparing.future.timeout(const Duration(seconds: 5));
      await job('agent_job_cancel', {'jobId': 'cancelled'});
      modelBytes.complete();
      Map? finalJob;
      for (var attempt = 0; attempt < 10; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        finalJob = await job('agent_job_status', {'jobId': 'cancelled'});
        if (finalJob['state'] == 'complete') break;
      }
      expect(finalJob!['state'], 'complete');
      expect((finalJob['result'] as Map)['status'], 'cancelled');
      expect(group.brainFor(actor)!.identity.modelHash, model.sha256);
      expect(ml.cache.diagnostics.leaseReferences, 0);
      await process.stdin.close();
      expect(
        await process.exitCode.timeout(const Duration(seconds: 20)),
        0,
        reason: await errors,
      );
      await replies.cancel();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
