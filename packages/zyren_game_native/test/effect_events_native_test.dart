@Tags(['native-gpu'])
library;

import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_particles/zyren_particles.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/effects.dart';

void main() {
  test(
    'real particle controller receives one burst and releases effects on scope close',
    () async {
      final backend = await NativeBackend.create();
      final plugin = ParticlePlugin(
        emitters: [
          ParticleEmitter(
            name: 'spark',
            autoStart: false,
            settings: ParticleSettings(
              capacity: 32,
              rate: 0,
              fixedStep: .01,
              lifetime: 1,
            ),
          ),
        ],
      );
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [plugin],
      );
      final events = GameEventBus();
      final scope = AttachmentScope();
      final errors = <Object>[];
      final effects = GameEffectEvents(
        events: events,
        particles: plugin.controller,
        scope: scope,
        onError: errors.add,
        capacity: 2,
      );
      final firstBinding = effects.bind('impact', 'spark');
      try {
        events.emit(
          0,
          GameEffectEvent(id: 'retired-binding', effect: 'impact', count: 7),
        );
        firstBinding.dispose();
        effects.bind('impact', 'spark');
        await effects.settled;
        await engine.render(elapsed: Duration.zero, width: 32, height: 32);
        await engine.render(
          elapsed: const Duration(milliseconds: 20),
          width: 32,
          height: 32,
        );
        expect(await plugin.controller.inspect('spark'), isEmpty);
        final event = GameEffectEvent(id: 'hit-1', effect: 'impact', count: 3);
        events.emit(1, event);
        events.emit(1, event);
        await effects.settled;
        await engine.render(elapsed: Duration.zero, width: 32, height: 32);
        await engine.render(
          elapsed: const Duration(milliseconds: 20),
          width: 32,
          height: 32,
        );
        expect(await plugin.controller.inspect('spark'), hasLength(3));
        expect(effects.pending, 0);
        expect(errors, isEmpty);
        scope.close();
        await scope.whenClosed;
        events.emit(
          1,
          GameEffectEvent(id: 'after-close', effect: 'impact', count: 3),
        );
        await engine.render(
          elapsed: const Duration(milliseconds: 40),
          width: 32,
          height: 32,
        );
        expect(await plugin.controller.inspect('spark'), isEmpty);
        expect(plugin.controller.isClosed, isFalse);
      } finally {
        scope.close();
        await scope.whenClosed;
        events.close();
        await engine.dispose();
      }
    },
  );
}
