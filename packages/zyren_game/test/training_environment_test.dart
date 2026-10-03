import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game/zyren_game.dart';
import 'save_replay_test.dart' as fixture;

class CommandCapture extends GameSystem {
  Object? last;
  @override
  String get id => 'capture';
  @override
  GamePhase get phase => GamePhase.controllers;
  @override
  void fixedUpdate(GameSession session) {
    for (final command in session.currentCommands) {
      last = command.payload;
    }
  }
}

GameTrainingScenario scenario({
  Future<void> Function()? wait,
  TrainingSplit split = TrainingSplit.training,
  CommandCapture? capture,
  void Function(GameSession)? configure,
}) => GameTrainingScenario(
  id: 'fixture',
  split: split,
  maxSteps: 2,
  create: (seed, episode) async {
    final session = GameSession(
      project: fixture.game().project,
      seed: seed,
      systems: [?capture],
    )..step();
    configure?.call(session);
    GameEntityHandle actor() => session.entities.entities
        .singleWhere((e) => e.handle.id == 'actor')
        .handle;
    return GameTrainingInstance(
      session: session,
      step: session.step,
      actors: () => [actor()],
      close: session.close,
      observe: () => {
        actor().id: Float32List.fromList([session.tick.toDouble()]),
      },
      observationSchemaHash: 'obs',
      actionSchemaHash: 'action',
      actionWidth: 2,
      beforeStep: wait,
    );
  },
);
Map<String, Object?> header(
  String operation,
  int sequence, {
  String episode = 'env-1',
  int tick = 1,
}) => {
  'version': 1,
  'operation': operation,
  'sequence': sequence,
  'run_id': 'run',
  'environment_id': 'env',
  'episode_id': episode,
  'actor_ids': ['actor'],
  'actor_generations': {'actor': 1},
  'tick': tick,
};
void main() {
  test('invalid actions and other data splits cannot mutate runtime', () async {
    final env = GameTrainingEnvironment(
      runId: 'run',
      environmentId: 'env',
      scenarios: {'fixture': scenario()},
    );
    final initial = await env.reset(seed: 7, scenario: 'fixture');
    final actor = (initial.info['actor_ids'] as List).single as String;
    await expectLater(
      env.step({
        actor: Float32List.fromList([double.nan, 0]),
      }),
      throwsArgumentError,
    );
    expect(env.instance!.session.tick, 1);
    expect(env.instance!.session.commands.length, 0);
    final step = await env.step({
      actor: Float32List.fromList([0, 0]),
    });
    expect(step.info['tick'], 2);
    expect(step.truncated, isFalse);
    expect(
      (await env.step({
        actor: Float32List.fromList([0, 0]),
      })).truncated,
      isTrue,
    );
    await expectLater(
      env.step({
        actor: Float32List.fromList([0, 0]),
      }),
      throwsStateError,
    );
    await env.close();
    final rejected = GameTrainingEnvironment(
      runId: 'run',
      environmentId: 'other',
      scenarios: {'fixture': scenario(split: TrainingSplit.test)},
    );
    await expectLater(
      rejected.reset(seed: 7, scenario: 'fixture'),
      throwsStateError,
    );
    await rejected.close();
  });
  test(
    'inference waits preserve tick and overlapping reset is rejected',
    () async {
      final gate = Completer<void>();
      final capture = CommandCapture();
      final env = GameTrainingEnvironment(
        runId: 'run',
        environmentId: 'env',
        scenarios: {
          'fixture': scenario(wait: () => gate.future, capture: capture),
        },
      );
      final reset = await env.reset(seed: 7, scenario: 'fixture');
      final actor = (reset.info['actor_ids'] as List).single as String;
      final pending = env.step({
        actor: Float32List.fromList([0, 0]),
      });
      await expectLater(
        env.reset(seed: 7, scenario: 'fixture'),
        throwsStateError,
      );
      expect(env.instance!.session.tick, 1);
      gate.complete();
      expect((await pending).info['tick'], 2);
      expect((capture.last as Map)['action'], [0, 0]);

      await env.close();
    },
  );
  test('supervisor rejects duplicate sequence and stale episode', () async {
    final supervisor = GameTrainingSupervisor(
      create: (run, id, purpose) async => LocalTrainingEndpoint(
        GameTrainingEnvironment(
          runId: run,
          environmentId: id,
          scenarios: {'fixture': scenario()},
          purpose: purpose,
        ),
      ),
    );
    final hello = TrainingFrame.float32(header('hello', 1), {});
    expect((await supervisor.dispatch(hello)).header['ok'], isTrue);
    expect((await supervisor.dispatch(hello)).header['ok'], isFalse);
    final reset = await supervisor.dispatch(
      TrainingFrame.float32({
        ...header('reset', 2),
        'seed': 7,
        'scenario': 'fixture',
      }, {}),
    );
    expect(reset.header['episode_id'], 'env-1');
    final stale = await supervisor.dispatch(
      TrainingFrame.float32(header('step', 3, episode: 'stale'), {
        'action.actor': Float32List.fromList([0, 0]),
      }),
    );
    expect(stale.header['ok'], isFalse);
    expect(stale.header['success'], isFalse);
    await supervisor.close();
  });
  test(
    'restore advances actor generations and rejects old generation requests',
    () async {
      final supervisor = GameTrainingSupervisor(
        create: (run, id, purpose) async => LocalTrainingEndpoint(
          GameTrainingEnvironment(
            runId: run,
            environmentId: id,
            scenarios: {'fixture': scenario()},
            purpose: purpose,
          ),
        ),
      );
      await supervisor.dispatch(TrainingFrame.float32(header('hello', 1), {}));
      await supervisor.dispatch(
        TrainingFrame.float32({
          ...header('reset', 2),
          'seed': 7,
          'scenario': 'fixture',
        }, {}),
      );
      final snapshot = await supervisor.dispatch(
        TrainingFrame.float32(header('snapshot', 3), {}),
      );
      final restored = await supervisor.dispatch(
        TrainingFrame.byteBlock(
          header('restore', 4),
          'snapshot',
          snapshot.bytes('snapshot'),
        ),
      );
      expect(restored.header['actor_generations'], {'actor': 2});
      final stale = await supervisor.dispatch(
        TrainingFrame.float32(header('step', 5), {
          'action.actor': Float32List.fromList([0, 0]),
        }),
      );
      expect(stale.header['ok'], isFalse);
      final valid = await supervisor.dispatch(
        TrainingFrame.float32(
          {
            ...header('step', 6),
            'actor_generations': {'actor': 2},
          },
          {
            'action.actor': Float32List.fromList([0, 0]),
          },
        ),
      );
      expect(valid.header['ok'], isTrue);
      expect(valid.header['tick'], 2);
      await supervisor.close();
    },
  );
  test('static level entities never enter action actor identities', () async {
    final capture = CommandCapture();
    final env = GameTrainingEnvironment(
      runId: 'run',
      environmentId: 'env',
      scenarios: {
        'fixture': scenario(
          capture: capture,
          configure: (s) {
            s.entities.spawn('ground');
            s.entities.spawn('gate');
          },
        ),
      },
    );
    final initial = await env.reset(seed: 7, scenario: 'fixture');
    expect(env.instance!.session.entities.length, 3);
    expect(initial.info['actor_ids'], ['actor']);
    final result = await env.step({
      'actor': Float32List.fromList([.5, 0]),
    });
    expect(result.info['actor_ids'], ['actor']);
    expect((capture.last as Map)['action'], [.5, 0]);
    await env.close();
  });
}
