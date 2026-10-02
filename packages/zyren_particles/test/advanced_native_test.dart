import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_particles/zyren_particles.dart';

void main() {
  test('world collision planes survive origin rebasing', () async {
    final backend = await NativeBackend.create();
    final owner = GpuScope.fromBackend(backend);
    try {
      for (final path in ParticlePath.values) {
        for (final height in [0.0, 6e8]) {
          final settings = ParticleSettings(
            capacity: 1,
            rate: 0,
            path: path,
            space: ParticleSpace.world,
            gravity: Vec3.zero,
            velocity: const Vec3(0, -1, 0),
            fixedStep: .1,
            collisions: [
              ParticlePlane(normal: const Vec3(0, 1, 0), offset: -height),
            ],
          );
          final renderer = await ParticleRenderer.create(owner, settings);
          final emitter = Group()..position = Vec3(0, height + .01, 0);
          await renderer.update(
            [const ParticleTick(1, 0, 1, .1), const ParticleTick(2, 1, 0, .1)],
            emitter: emitter.localMatrix,
            camera: Mat4.identity(),
          );
          final p = (await renderer.inspect()).single;
          expect(p.position.y, closeTo(height, 1e-6));
          expect(p.velocity.y, closeTo(.5, 1e-6));
          await renderer.close();
        }
      }
    } finally {
      await owner.close();
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');

  test(
    'large world origins preserve small particles and invalid batches are atomic',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      try {
        for (final path in ParticlePath.values) {
          final images = <List<int>>[];
          for (final offset in [Vec3.zero, const Vec3(6e8, -3e8, 2e8)]) {
            final settings = ParticleSettings(
              capacity: 2,
              rate: 0,
              path: path,
              space: ParticleSpace.world,
              gravity: Vec3.zero,
              velocity: const Vec3(.1, 0, 0),
              size: ParticleCurve.constant(.1),
            );
            final renderer = await ParticleRenderer.create(owner, settings);
            final scene = Scene()..background = const Color3(0, 0, 0);
            final emitter = scene.add(Group())..position = offset;
            emitter.add(renderer.mesh);
            final camera = OrthographicCamera(
              left: -.5,
              right: .5,
              top: .5,
              bottom: -.5,
              near: .1,
              far: 10,
              position: offset + const Vec3(0, 0, 3),
              target: offset,
            );
            await expectLater(
              renderer.update(
                [
                  ParticleTick(1, 0, 1, settings.fixedStep),
                  ParticleTick(3, 1, 1, settings.fixedStep),
                ],
                emitter: emitter.localMatrix,
                camera: particleCameraTransform(camera),
              ),
              throwsArgumentError,
            );
            expect(await renderer.inspect(), isEmpty);
            await renderer.update(
              [
                for (var i = 1; i <= 12; i++)
                  ParticleTick(i, 0, i == 1 ? 1 : 0, settings.fixedStep),
              ],
              emitter: emitter.localMatrix,
              camera: particleCameraTransform(camera),
            );
            final particle = (await renderer.inspect()).single;
            expect(
              particle.position.x - offset.x,
              closeTo(11 * settings.fixedStep * .1, 1e-6),
            );
            images.add(
              ((await backend.render(
                        FrameSubmission.capture(
                          scene: scene,
                          camera: camera,
                          size: PhysicalSize(64, 64),
                        ),
                      ))
                      as ReadbackOutput)
                  .image
                  .pixels,
            );
            await renderer.close();
          }
          expect(images[1], images[0], reason: path.name);
          expect(
            images[0].where((value) => value > 0).length,
            greaterThan(4096),
          );
        }
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'world particles retain birth transforms and noise matches reference',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      try {
        for (final appearance in [
          ParticleAppearance.oriented,
          ParticleAppearance.mesh,
        ]) {
          final box = BoxGeometry();
          final settings = ParticleSettings(
            capacity: 8,
            rate: 0,
            space: ParticleSpace.world,
            appearance: appearance,
            mesh: appearance == ParticleAppearance.mesh
                ? GeometryData(attributes: box.attributes, indices: box.indices)
                : null,
            fixedStep: .01,
            gravity: Vec3.zero,
            size: ParticleCurve.constant(.2),
            trails: TrailSettings(samples: 8),
            velocity: const Vec3(.1, .2, .1),
            forces: [NoiseParticleForce(amplitude: .2, frequency: 1.3)],
            velocitySpread: const Vec3(.1, .1, .1),
          );
          final renderer = await ParticleRenderer.create(owner, settings),
              reference = ParticleReference(settings);
          final scene = Scene()..background = const Color3(0, 0, 0);
          final parent = scene.add(Group())
            ..quaternion = Quat.axisAngle(const Vec3(0, 0, 1), .4)
            ..scale = const Vec3(2, 1, 1);
          parent.add(renderer.mesh);
          parent.add(renderer.ribbon!);
          final birth = parent.localMatrix;
          final camera = OrthographicCamera(
            left: -1,
            right: 1,
            top: 1,
            bottom: -1,
            near: .1,
            far: 10,
            position: const Vec3(0, 0, 3),
          );
          final ticks = [
            for (var i = 1; i <= 30; i++)
              ParticleTick(i, 0, i == 1 ? 6 : 0, .01),
          ];
          for (final tick in ticks) {
            reference.step(tick, emitterTransform: birth);
          }
          await renderer.update(
            ticks,
            emitter: birth,
            camera: particleCameraTransform(camera),
          );
          final actual = await renderer.inspect(),
              expected = reference.particles;
          for (var i = 0; i < actual.length; i++) {
            expect(
              actual[i].position.distanceTo(expected[i].position),
              lessThan(2e-5),
            );
            expect(actual[i].birthScale.x, closeTo(2, 1e-6));
          }
          final bounds = await renderer.inspectBounds();
          for (final particle in actual) {
            expect(bounds!.contains(particle.position), isTrue);
          }
          Future<List<int>> image() async =>
              ((await backend.render(
                        FrameSubmission.capture(
                          scene: scene,
                          camera: camera,
                          size: PhysicalSize(64, 64),
                        ),
                      ))
                      as ReadbackOutput)
                  .image
                  .pixels;
          final before = await image();
          parent.position = const Vec3(30, 40, 50);
          parent.rotateZ(1);
          parent.scale = const Vec3(4, 3, 2);
          await renderer.update(
            [],
            emitter: parent.localMatrix,
            camera: particleCameraTransform(camera),
          );
          expect(
            await image(),
            before,
            reason: 'World particles must keep birth orientation and scale.',
          );
          await renderer.close();
        }
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'maximum capacity sorts across graph limits and reports measured work',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      try {
        final settings = ParticleSettings(
          capacity: 65536,
          rate: 0,
          gravity: Vec3.zero,
          shape: BoxParticleShape(),
          size: ParticleCurve.constant(.01),
        );
        final watch = Stopwatch()..start();
        final renderer = await ParticleRenderer.create(owner, settings);
        watch.stop();
        final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
        await renderer.update(
          [ParticleTick(1, 0, 65536, settings.fixedStep)],
          emitter: Mat4.identity(),
          camera: particleCameraTransform(camera),
        );
        expect((await renderer.inspect()).length, 65536);
        expect(renderer.measurements.dispatches, 138);
        expect(renderer.measurements.uploadedBytes, 448);
        final stats = await backend.resourceStats();
        final evidence = Platform.environment['ZYREN_PARTICLE_EVIDENCE'];
        if (evidence != null) {
          Directory(evidence).createSync(recursive: true);
          File('$evidence/capacity.json').writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
              'capacity': 65536,
              'creationMicroseconds': watch.elapsedMicroseconds,
              'updateHostMicroseconds':
                  renderer.measurements.hostTime.inMicroseconds,
              'dispatches': renderer.measurements.dispatches,
              'uploadedBytes': renderer.measurements.uploadedBytes,
              'residentBytes': stats.residentBytes,
              'liveCountFromExplicitReadback': 65536,
              'gpuTime': null,
              'routineReadbackBytes': 0,
            }),
          );
        }
        await renderer.close();
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'reference fallback rejects concurrent mutation and drains accepted work on close',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      try {
        final s = ParticleSettings(
          capacity: 4,
          path: ParticlePath.reference,
          rate: 0,
        );
        final renderer = await ParticleRenderer.create(owner, s);
        final update = renderer.update(
          [ParticleTick(1, 0, 2, s.fixedStep)],
          emitter: Mat4.identity(),
          camera: Mat4.identity(),
        );
        await expectLater(renderer.reset(), throwsStateError);
        final close = renderer.close();
        await update;
        await close;
        expect((await backend.resourceStats()).residentBytes, 0);
        await expectLater(renderer.inspect(), throwsStateError);
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
