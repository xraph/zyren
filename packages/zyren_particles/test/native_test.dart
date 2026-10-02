import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_particles/zyren_particles.dart';

void main() {
  test(
    'Metal compute agrees with reference and native particles render',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      try {
        final s = ParticleSettings(
          capacity: 16,
          rate: 0,
          fixedStep: .01,
          lifetime: 1,
          shape: BoxParticleShape(halfExtent: const Vec3(.4, .4, .4)),
          velocity: const Vec3(0, 1, 0),
          gravity: const Vec3(0, -1, 0),
          size: ParticleCurve.constant(.2),
          trails: TrailSettings(samples: 4),
        );
        final gpu = await ParticleRenderer.create(owner, s);
        final reference = ParticleReference(s);
        final ticks = [
          for (var i = 1; i <= 10; i++) ParticleTick(i, 8, i == 1 ? 8 : 0, .01),
        ];
        for (final t in ticks) {
          reference.step(t);
        }
        final camera = OrthographicCamera(
          left: -1,
          right: 1,
          top: 1,
          bottom: -1,
          near: .1,
          far: 10,
          position: const Vec3(0, 0, 3),
        );
        await gpu.update(
          ticks,
          emitter: Mat4.identity(),
          camera: particleCameraTransform(camera),
        );
        final actual = await gpu.inspect(), expected = reference.particles;
        expect(actual.length, expected.length);
        for (var i = 0; i < actual.length; i++) {
          expect(actual[i].serial, expected[i].serial);
          expect(
            actual[i].position.distanceTo(expected[i].position),
            lessThan(1e-5),
          );
          expect(
            actual[i].velocity.distanceTo(expected[i].velocity),
            lessThan(1e-5),
          );
        }
        final scene = Scene()..background = const Color3(0, 0, 0);
        scene.add(gpu.mesh);
        scene.add(gpu.ribbon!);
        final output =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(128, 128),
                  ),
                )
                as ReadbackOutput;
        expect(
          output.image.pixels.where((v) => v > 0).length,
          greaterThan(128 * 128),
        );
        expect(gpu.measurements.dispatches, greaterThanOrEqualTo(10));
        await gpu.reset();
        expect(await gpu.inspect(), isEmpty);
        await gpu.close();
        await backend.render(
          FrameSubmission.capture(
            scene: scene,
            camera: camera,
            size: PhysicalSize(16, 16),
          ),
        );
        expect((await backend.resourceStats()).residentBytes, 0);
        expect((await backend.graphStats()).liveMaterials, 0);
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
