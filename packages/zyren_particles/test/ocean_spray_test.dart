import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_particles/zyren_particles.dart';
import 'package:zyren_particles/ocean.dart';

void main() {
  test(
    'native spray replays across display rates with bounded independent admission',
    () async {
      final backend = await NativeBackend.create();
      final plugin = ParticlePlugin(emitters: []);
      final anchor = const Vec3(6378137, 0, 0);
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(
          position: anchor + const Vec3(0, 0, 5),
          target: anchor,
        ),
        backendFactory: () async => backend.createView(),
        plugins: [plugin],
      );
      final control = plugin.controller;
      OceanSprayParticles? spray;
      Future<List<ParticleSnapshot>> snapshots() async => [
        for (final name in spray!.emitterNames) ...await control.inspect(name),
      ];
      OceanSprayEvent event(
        String source,
        int sequence,
        int tick,
        int generation,
      ) => OceanSprayEvent(
        source: source,
        sequence: sequence,
        tick: tick,
        generation: generation,
        position: anchor + Vec3(tick / 10, 0, 0),
        velocity: const Vec3(2, 0, 0),
        surfaceNormal: const Vec3(0, 1, 0),
        energy: 1,
      );
      try {
        await engine.render(elapsed: Duration.zero, width: 32, height: 32);
        final before = await backend.resourceStats();
        final disabled = await OceanSprayParticles.create(control, budget: 0);
        expect(disabled.emitterNames, isEmpty);
        expect(await disabled.advance(1, events: [event('hull', 0, 1, 0)]), [
          OceanSprayAdmission.disabled,
        ]);
        expect(
          (await backend.resourceStats()).liveAllocations,
          before.liveAllocations,
        );
        await disabled.close();
        spray = await OceanSprayParticles.create(
          control,
          anchor: anchor,
          budget: 16,
          maxEventsPerTick: 2,
          maxSources: 2,
          particlesPerEvent: 4,
          gravity: const Vec3(0, -9.81, 0),
        );

        final results = await spray.advance(
          1,
          events: [
            event('c', 0, 1, 0),
            event('b', 0, 1, 0),
            event('a', 0, 1, 0),
            event('a', 0, 1, 0),
          ],
        );
        expect(results, [
          OceanSprayAdmission.sourceBudget,
          OceanSprayAdmission.accepted,
          OceanSprayAdmission.accepted,
          OceanSprayAdmission.duplicate,
        ]);
        final birth = await snapshots();
        expect(birth.length, 8);
        expect(
          birth.every(
            (p) => p.position.distanceTo(anchor + const Vec3(.1, 0, 0)) < .04,
          ),
          isTrue,
        );
        expect(
          birth.every((p) => p.velocity.y > 3.7 && p.velocity.x > 1.7),
          isTrue,
        );
        await engine.render(
          elapsed: const Duration(milliseconds: 1),
          width: 32,
          height: 32,
        );
        final allocated = (await backend.resourceStats()).liveAllocations;
        final reference = <ParticleSnapshot>[];
        var elapsed = 0;
        for (var tick = 2; tick <= 30; tick++) {
          await spray.advance(tick);
          elapsed += 16;
          await engine.render(
            elapsed: Duration(milliseconds: elapsed),
            width: 32,
            height: 32,
          );
        }
        reference.addAll(await snapshots());
        await spray.reset(1);
        await spray.advance(
          1,
          events: [event('a', 0, 1, 1), event('b', 0, 1, 1)],
        );
        for (var tick = 2; tick <= 30; tick++) {
          await spray.advance(tick);
          for (var frame = 0; frame < 3; frame++) {
            elapsed += 6;
            await engine.render(
              elapsed: Duration(milliseconds: elapsed),
              width: 32,
              height: 32,
            );
          }
        }
        final replay = await snapshots();
        expect(replay.length, reference.length);
        for (var i = 0; i < replay.length; i++) {
          expect(replay[i].position, reference[i].position);
          expect(replay[i].velocity, reference[i].velocity);
          expect(replay[i].age, reference[i].age);
        }
        expect((await backend.resourceStats()).liveAllocations, allocated);
        await expectLater(spray.advance(30), throwsStateError);
        expect(
          await spray.advance(
            31,
            events: [event('a', 0, 31, 1), event('b', 1, 31, 0)],
          ),
          [OceanSprayAdmission.duplicate, OceanSprayAdmission.wrongTime],
        );
        final pending = spray.advance(32);
        final closing = spray.close();
        await pending;
        await closing;
        expect(control.names, isEmpty);
        expect(engine.scene.children, isEmpty);
        await engine.render(
          elapsed: Duration(milliseconds: elapsed + 10),
          width: 32,
          height: 32,
        );
        expect(
          (await backend.resourceStats()).liveAllocations,
          before.liveAllocations,
        );
      } finally {
        await spray?.close();
        await engine.dispose();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
