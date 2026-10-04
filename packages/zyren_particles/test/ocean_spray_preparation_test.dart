import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_particles/zyren_particles.dart';
import 'package:zyren_particles/ocean.dart';

void main() {
  test(
    'detached spray candidates admit payload and resume an existing fixed clock',
    () async {
      final backend = await NativeBackend.create();
      final plugin = ParticlePlugin(emitters: []);
      final scene = Scene();
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        backendFactory: () async => backend.createView(),
        plugins: [plugin],
      );
      OceanSprayParticles? candidate;
      try {
        await engine.render(elapsed: Duration.zero, width: 16, height: 16);
        final before = (await backend.resourceStats()).residentBytes;
        final old = await OceanSprayParticles.create(
          plugin.controller,
          budget: 0,
        );
        await old.advance(1);
        final bytes = OceanSprayParticles.estimateBytes(
          budget: 16,
          maxEventsPerTick: 2,
        );
        await expectLater(
          OceanSprayParticles.create(
            plugin.controller,
            budget: 16,
            maxEventsPerTick: 2,
            maxLogicalBytes: bytes - 1,
          ),
          throwsA(isA<ResourceException>()),
        );
        expect(plugin.controller.names, isEmpty);
        candidate = await OceanSprayParticles.create(
          plugin.controller,
          budget: 16,
          maxEventsPerTick: 2,
          autoAttach: false,
          initialTick: 10,
          generation: 3,
          sourceWatermarks: {'vessel': 7},
          maxLogicalBytes: bytes,
          particlesPerEvent: 1,
        );
        expect(scene.children, isEmpty);
        expect(candidate.tick, 10);
        expect(candidate.logicalBytes, bytes);
        expect(
          (await backend.resourceStats()).residentBytes - before,
          candidate.scopedBytes,
        );
        OceanSprayEvent event(int sequence) => OceanSprayEvent(
          source: 'vessel',
          sequence: sequence,
          tick: 11,
          generation: 3,
          position: Vec3.zero,
          velocity: Vec3.zero,
          surfaceNormal: const Vec3(0, 1, 0),
          energy: 1,
        );
        expect(await candidate.advance(11, events: [event(7), event(8)]), [
          OceanSprayAdmission.duplicate,
          OceanSprayAdmission.accepted,
        ]);
        expect(candidate.sourceWatermarks, {'vessel': 8});
        for (final object in candidate.objects) {
          scene.add(object);
        }
        await engine.render(
          elapsed: const Duration(milliseconds: 20),
          width: 16,
          height: 16,
        );
        // Payload includes native particle buffers, sprites and uploaded geometry.
        expect(
          (await backend.resourceStats()).residentBytes - before,
          greaterThanOrEqualTo(bytes),
        );
        expect(
          candidate.emitterNames.every(
            (name) => plugin.controller.simulationTick(name) == 1,
          ),
          isTrue,
        );
        await candidate.advance(12);
        await candidate.reset(4);
        expect(candidate.tick, 0);
        expect(candidate.sourceWatermarks, isEmpty);
        await candidate.advance(1);
        await candidate.close();
        await old.close();
        expect(scene.children, isEmpty);
        await engine.render(
          elapsed: const Duration(milliseconds: 40),
          width: 16,
          height: 16,
        );
        expect((await backend.resourceStats()).residentBytes, before);
      } finally {
        await candidate?.close();
        await engine.dispose();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
