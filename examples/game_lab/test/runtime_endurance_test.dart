import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_lab/game_session.dart';

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
  for (final name in ['exploration', 'vehiclePlayground']) {
    test(
      '$name keeps native actors on its authored floor for 20 seconds',
      () async {
        final game = await GameLabSession.load(
          await File('games/$name.zygame').readAsBytes(),
        );
        SceneEngine? engine;
        try {
          engine = await SceneEngine.create(
            scene: game.scene.scene,
            camera: game.scene.camera,
            rendererFactory: () async => _ClockRenderer(),
            plugins: game.runtime.plugins,
          );
          game.runtime.simulation!.step();
          await game.ai.flush();
          final actor = game.ai.actors.single;
          var invalidBody = 0;
          for (var i = 0; i < 1000; i++) {
            game.runtime.simulation!.step();
            await game.ai.flush();
            final frame = game.ai.observation(actor)!;
            if (i > 50 &&
                frame.readings.any(
                  (r) => r.sensorId == 'body' && r.state.name != 'known',
                )) {
              invalidBody++;
            }
            final position = game.runtime
                .resolveBody(actor)!
                .state
                .pose
                .position;
            expect(
              position.y,
              greaterThan(-1),
              reason: '$name fell off the level at tick ${game.session.tick}',
            );
            expect(position.x.abs(), lessThan(15));
            expect(position.z.abs(), lessThan(15));
          }
          expect(invalidBody, 0);
          expect(game.ai.completedDecisions, greaterThan(900));
        } finally {
          await engine?.dispose();
          await game.close();
        }
      },
    );
  }
}
