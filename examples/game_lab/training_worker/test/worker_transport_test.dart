import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_lab_training_worker/worker_transport.dart';

Map<String, GameTrainingScenario> fixtureCatalog() => {
  'fixture': GameTrainingScenario(
    id: 'fixture',
    split: TrainingSplit.training,
    create: (seed, episode) async {
      final registry = GameRegistry();
      final project = CompiledGameProject(
        project: GameProject(
          id: 'transport',
          startupLevel: 'level',
          registry: registry,
          levels: [
            GameLevel(
              id: 'level',
              scene: GameSceneIdentity('transport', '1'),
              entities: [
                GameEntityRecord(id: 'actor', nodeId: 'actor', components: []),
              ],
            ),
          ],
        ),
        systemVersions: {},
      );
      final session = GameSession(project: project, seed: seed)..step();
      return GameTrainingInstance(
        session: session,
        step: session.step,
        close: session.close,
        actors: () => [session.entities.entities.single.handle],
        observe: () => {
          'actor': Float32List.fromList([session.tick.toDouble()]),
        },
        observationSchemaHash: 'observation',
        actionSchemaHash: 'action',
        actionWidth: 1,
      );
    },
  ),
};

void main() {
  test(
    'shared isolate transport negotiates, steps and drains real endpoint ownership',
    () async {
      final input = StreamController<List<int>>(),
          responses = <int, Completer<TrainingFrame>>{};
      final decoder = TrainingFrameDecoder();
      final serving = runTrainingProtocol(
        fixtureCatalog,
        input: input.stream,
        capabilities: const {'structured'},
        onResponse: (bytes) async {
          for (final frame in decoder.add(bytes)) {
            responses[frame.header['sequence']]!.complete(frame);
          }
        },
      );
      Map<String, Object?> last = {};
      Future<TrainingFrame> request(
        String operation,
        int sequence, {
        Map<String, Object?> extra = const {},
        Map<String, Float32List> arrays = const {},
      }) {
        final completer = responses[sequence] = Completer<TrainingFrame>();
        input.add(
          TrainingFrame.float32({
            'version': 1,
            'operation': operation,
            'sequence': sequence,
            'run_id': 'transport',
            'environment_id': 'env',
            'episode_id': last['episode_id'] ?? 'reset',
            'tick': last['tick'] ?? 0,
            'actor_ids': last['actor_ids'] ?? [],
            'actor_generations':
                last['actor_generations'] ?? <String, Object?>{},
            ...extra,
          }, arrays).encode(),
        );
        return completer.future.timeout(const Duration(seconds: 3));
      }

      try {
        final hello = await request('hello', 0);
        expect(hello.header['ok'], true);
        expect(hello.header['capabilities'], ['structured']);
        final reset = await request(
          'reset',
          1,
          extra: {'scenario': 'fixture', 'seed': 7},
        );
        last = reset.header;
        expect(reset.float32('observation.actor'), [1]);
        final stepped = await request(
          'step',
          2,
          arrays: {
            'action.actor': Float32List.fromList([0]),
          },
        );
        last = stepped.header;
        expect(stepped.float32('observation.actor'), [2]);
        expect((await request('close', 3)).header['ok'], true);
      } finally {
        await input.close();
        await serving;
      }
    },
  );
}
