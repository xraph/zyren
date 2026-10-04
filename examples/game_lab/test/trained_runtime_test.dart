import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_ai/runtime.dart';
import 'package:zyren_game_lab/game_session.dart';
import 'package:zyren_game_native/zyren_game_native.dart';

// This fixture supplies the plugin lifecycle clock. Physics and inference are
// native; rendering is deliberately unavailable and establishes no GPU evidence.
final class _ClockRenderer implements SceneRenderer {
  @override
  final capabilities = RendererCapabilities(
    name: 'game-lab-clock-only',
    features: {RenderFeatures.indexedMeshes, RenderFeature.portablePrimitives},
    maxDimension: 128,
  );
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) => throw UnsupportedError('This test does not render frames.');
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final entry in {
    'exploration': 'guard',
    'vehiclePlayground': 'vehicle',
  }.entries) {
    test(
      '${entry.key} runs its accepted offline policy and restores native brain state',
      () async {
        final game = await GameLabSession.load(
          await File('games/${entry.key}.zygame').readAsBytes(),
        );
        SceneEngine? engine;
        try {
          final artifact = game.modelArtifacts.values.single;
          expect(artifact.family, entry.value);
          expect(artifact.evaluation.accepted, isTrue);
          expect(game.project.fixedHz, artifact.fixedHz);
          engine = await SceneEngine.create(
            scene: game.scene.scene,
            camera: game.scene.camera,
            rendererFactory: () async => _ClockRenderer(),
            plugins: game.runtime.plugins,
          );
          Future<void> step([int count = 1]) async {
            for (var i = 0; i < count; i++) {
              game.runtime.simulation!.step();
              await game.ai.flush();
            }
          }

          await step(20);
          final actor = game.ai.actors.single;
          final info = game.ai.inspect(actor);
          expect(info['modelHash'], artifact.contract.model.sha256);
          expect(info['modelFailure'], isNull);
          expect(info['completedDecisions'], greaterThan(0), reason: '$info');
          expect(info['stateVersion'], greaterThan(0));
          expect(info['receipts'], isNotEmpty);
          final sounds = <GameSoundEvent>[];
          final listener = game.session.events.listen((event) {
            if (event.payload case final GameSoundEvent sound) {
              sounds.add(sound);
            }
          });
          game.actions.setAxis(
            deviceId: 'test-keyboard',
            action: 'move.x',
            value: 1,
          );
          await step(20);
          game.actions.releaseEveryDevice();
          listener.cancel();
          expect(
            sounds,
            isNotEmpty,
            reason: 'Native player motion emits hearing events.',
          );
          if (entry.value == 'vehicle') {
            final hazard = game.session.entities.entities
                .singleWhere((e) => e.handle.id == 'moving-hazard')
                .handle;
            final x = game.runtime.resolveBody(hazard)!.state.pose.position.x;
            expect(x, isNot(closeTo(-5, .01)));
          }
          final saved = await game.ai.save();
          final savedTick = game.session.tick;
          final savedVersion = game.ai.inspect(actor)['stateVersion'];
          final savedPosition = game.runtime
              .resolveBody(actor)!
              .state
              .pose
              .position;
          game.runtime.resume();
          await step(10);
          await game.ai.restore(saved);
          final restored = game.ai.actors.single;
          expect(restored.id, actor.id);
          expect(restored.generation, greaterThan(actor.generation));
          expect(game.session.tick, savedTick);
          expect(game.ai.inspect(restored)['stateVersion'], savedVersion);
          expect(
            (game.runtime.resolveBody(restored)!.state.pose.position -
                    savedPosition)
                .length,
            lessThan(.00001),
          );
          game.runtime.resume();
          await step(4);
          expect(
            game.ai.inspect(restored)['stateVersion'],
            greaterThan(savedVersion as int),
          );
        } finally {
          await engine?.dispose();
          await game.close();
        }
      },
    );
  }
}
