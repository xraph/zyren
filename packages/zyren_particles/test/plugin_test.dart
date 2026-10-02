import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_particles/zyren_particles.dart';

void main() {
  test(
    'plugin isolates scenes, pauses, resets, restores and reattaches',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene();
      final existing = scene.add(Group(name: 'existing'));
      final plugin = ParticlePlugin(
        emitters: [
          ParticleEmitter(
            name: 'test',
            object: existing,
            settings: ParticleSettings(
              capacity: 32,
              rate: 20,
              fixedStep: .01,
              lifetime: .2,
              prewarm: .1,
            ),
          ),
        ],
      );
      SceneEngine? engine;
      final second = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend.createView(),
        plugins: [
          ParticlePlugin(
            emitters: [
              ParticleEmitter(
                name: 'test',
                settings: ParticleSettings(capacity: 8, rate: 0),
              ),
            ],
          ),
        ],
      );
      try {
        engine = await SceneEngine.create(
          scene: scene,
          camera: PerspectiveCamera(),
          backendFactory: () async => backend.createView(),
          plugins: [plugin],
        );
        Future<void> render(int ms, {int width = 48}) async {
          await engine!.render(
            elapsed: Duration(milliseconds: ms),
            width: width,
            height: 32,
          );
        }

        await render(0);
        expect((await plugin.controller.inspect('test')).length, 2);
        await render(100);
        final before = await plugin.controller.inspect('test');
        await plugin.controller.pause('test');
        await render(200, width: 64);
        await render(300);
        final paused = await plugin.controller.inspect('test');
        expect(paused.map((p) => p.position), before.map((p) => p.position));
        await plugin.controller.resume('test');
        await render(400);
        expect(
          (await plugin.controller.inspect('test')).length,
          greaterThan(0),
        );
        await plugin.controller.pause('test');
        final original = await plugin.controller.inspect('test');
        await expectLater(
          plugin.controller.configure(
            'test',
            ParticleSettings(softIntersections: true),
          ),
          throwsUnsupportedError,
        );
        expect(
          (await plugin.controller.inspect('test')).map((p) => p.position),
          original.map((p) => p.position),
        );
        await plugin.controller.configure(
          'test',
          ParticleSettings(
            capacity: 12,
            rate: 20,
            fixedStep: .01,
            lifetime: .2,
            prewarm: .1,
          ),
        );
        expect(plugin.controller.playback('test'), ParticlePlayback.paused);
        expect((await plugin.controller.inspect('test')).length, 2);
        await plugin.controller.reset('test');
        await render(500);
        expect(await plugin.controller.inspect('test'), isEmpty);
        await plugin.controller.burst('test', 5);
        await render(510);
        expect((await plugin.controller.inspect('test')).length, 5);
        await plugin.controller.restore('test');
        await render(520);
        expect(plugin.controller.playback('test'), ParticlePlayback.playing);
        await plugin.controller.stop('test');
        await render(750);
        await render(900);
        expect(plugin.controller.playback('test'), ParticlePlayback.stopped);
        await plugin.controller.add(
          ParticleEmitter(
            name: 'extra',
            settings: ParticleSettings(capacity: 2),
          ),
        );
        await plugin.controller.remove('extra');
        expect(plugin.controller.names, ['test']);
        final controller = plugin.controller;
        await engine.dispose();
        engine = null;
        expect(existing.parent, same(scene));
        expect(existing.children, isEmpty);
        expect(controller.isClosed, isTrue);
        await expectLater(controller.start('test'), throwsStateError);
        engine = await SceneEngine.create(
          scene: scene,
          camera: PerspectiveCamera(),
          backendFactory: () async => backend.createView(),
          plugins: [plugin],
        );
        expect(plugin.controller, isNot(same(controller)));
        await render(0);
        expect((await plugin.controller.inspect('test')).length, 2);
        await engine.dispose();
        engine = null;
        await second.dispose();
        expect((await backend.resourceStats()).residentBytes, 0);
        expect((await backend.graphStats()).liveMaterials, 0);
      } finally {
        await engine?.dispose();
        await second.dispose();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'unsupported soft depth and failed attach release partial initialization',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene();
      try {
        await expectLater(
          SceneEngine.create(
            scene: scene,
            camera: PerspectiveCamera(),
            backendFactory: () async => backend.createView(),
            plugins: [
              ParticlePlugin(
                emitters: [
                  ParticleEmitter(
                    name: 'first',
                    settings: ParticleSettings(capacity: 4),
                  ),
                  ParticleEmitter(
                    name: 'unsupported',
                    settings: ParticleSettings(softIntersections: true),
                  ),
                ],
              ),
            ],
          ),
          throwsA(anything),
        );
        expect(scene.children, isEmpty);
        expect((await backend.resourceStats()).residentBytes, 0);
        expect((await backend.graphStats()).liveGraphs, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
