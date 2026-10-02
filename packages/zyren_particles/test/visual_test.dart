import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_particles/zyren_particles.dart';

GeometryData geometryData(BufferGeometry geometry) =>
    GeometryData(attributes: geometry.attributes, indices: geometry.indices);

void main() {
  test(
    'native images cover every mode, surface, sprites, forces and fallback',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final evidence = Platform.environment['ZYREN_PARTICLE_EVIDENCE'];
      if (evidence != null) Directory(evidence).createSync(recursive: true);
      final records = <Map<String, Object?>>[];
      try {
        final texture = ParticleTexture(
          width: 2,
          height: 1,
          rgba: Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255]),
          columns: 2,
          framesPerSecond: 20,
        );
        final camera = OrthographicCamera(
          left: -1,
          right: 1,
          bottom: -1,
          top: 1,
          near: .1,
          far: 10,
          position: const Vec3(0, 0, 3),
        );
        final shape = SurfaceParticleShape(
          geometryData(PlaneGeometry(width: .7, height: .7)),
        );
        for (final appearance in ParticleAppearance.values) {
          for (final blend in ParticleBlend.values) {
            ParticleSettings settings(ParticlePath path) => ParticleSettings(
              capacity: 16,
              rate: 0,
              path: path,
              fixedStep: .01,
              lifetime: 2,
              gravity: const Vec3(0, -.2, 0),
              appearance: appearance,
              blend: blend,
              mesh: appearance == ParticleAppearance.mesh
                  ? geometryData(BoxGeometry())
                  : null,
              shape: shape,
              texture: texture,
              size: ParticleCurve([CurveKey(0, .1), CurveKey(1, .3)]),
              rotation: ParticleCurve([CurveKey(0, 0), CurveKey(1, 2)]),
              velocitySpread: const Vec3(.3, .3, .3),
              forces: [FlowParticleForce(amplitude: .2)],
              trails: TrailSettings(samples: 4, width: .4),
              collisions: [
                ParticlePlane(normal: const Vec3(0, 1, 0), offset: .4),
              ],
            );
            final images = <Uint8List>[];
            for (final path in ParticlePath.values) {
              final renderer = await ParticleRenderer.create(
                owner,
                settings(path),
              );
              final scene = Scene()..background = const Color3(0, 0, 0);
              scene.add(renderer.mesh);
              scene.add(renderer.ribbon!);
              final ticks = [
                for (var i = 1; i <= 20; i++)
                  ParticleTick(i, 0, i == 1 ? 12 : 0, .01),
              ];
              await renderer.update(
                ticks,
                emitter: Mat4.identity(),
                camera: particleCameraTransform(camera),
              );
              final output =
                  await backend.render(
                        FrameSubmission.capture(
                          scene: scene,
                          camera: camera,
                          size: PhysicalSize(96, 96),
                        ),
                      )
                      as ReadbackOutput;
              images.add(output.image.pixels);
              final lit = [
                for (var i = 0; i < output.image.pixels.length; i += 4)
                  if (output.image.pixels[i] +
                          output.image.pixels[i + 1] +
                          output.image.pixels[i + 2] >
                      0)
                    i,
              ].length;
              expect(
                lit,
                greaterThan(20),
                reason: '${appearance.name}/${blend.name}/${path.name}',
              );
              final stats = await backend.resourceStats();
              records.add({
                'mode': appearance.name,
                'blend': blend.name,
                'path': path.name,
                'litPixels': lit,
                'residentBytes': stats.residentBytes,
                'hostMicroseconds':
                    renderer.measurements.hostTime.inMicroseconds,
                'dispatches': renderer.measurements.dispatches,
                'uploadedBytes': renderer.measurements.uploadedBytes,
              });
              if (evidence != null && path == ParticlePath.gpu) {
                File(
                  '$evidence/${appearance.name}_${blend.name}.rgba',
                ).writeAsBytesSync(output.image.pixels);
              }
              await renderer.close();
            }
            var error = 0;
            for (var i = 0; i < images[0].length; i++) {
              error += (images[0][i] - images[1][i]).abs();
            }
            expect(
              error / images[0].length,
              lessThan(1),
              reason: 'GPU/reference image error',
            );
          }
        }
        await backend.render(
          FrameSubmission.capture(
            scene: Scene(),
            camera: camera,
            size: PhysicalSize(16, 16),
          ),
        );
        expect((await backend.resourceStats()).residentBytes, 0);
        if (evidence != null) {
          File('$evidence/measurements.json').writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(records),
          );
        }
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test('depth tests have visible native effects', () async {
    final backend = await NativeBackend.create();
    final owner = GpuScope.fromBackend(backend);
    final camera = OrthographicCamera(
      left: -1,
      right: 1,
      bottom: -1,
      top: 1,
      near: .1,
      far: 10,
      position: const Vec3(0, 0, 3),
    );
    try {
      Future<List<int>> sample({
        required bool depthTest,
        required bool depthWrite,
      }) async {
        final s = ParticleSettings(
          capacity: 1,
          rate: 0,
          gravity: Vec3.zero,
          size: ParticleCurve.constant(1),
          blend: ParticleBlend.opaque,
          depthTest: depthTest,
          depthWrite: depthWrite,
          color: ParticleGradient.solid(const Color3(1, 0, 0)),
        );
        final renderer = await ParticleRenderer.create(owner, s);
        final scene = Scene()..background = const Color3(0, 0, 0);
        scene
            .add(
              Mesh(
                PlaneGeometry(width: 2, height: 2),
                UnlitMaterial(color: const Color3(0, 1, 0)),
              ),
            )
            .position = const Vec3(
          0,
          0,
          1,
        );
        scene.add(renderer.mesh);
        await renderer.update(
          [ParticleTick(1, 0, 1, s.fixedStep)],
          emitter: Mat4.identity(),
          camera: particleCameraTransform(camera),
        );
        final output =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(32, 32),
                  ),
                )
                as ReadbackOutput;
        final pixels = output.image.pixels.sublist(
          (16 * 32 + 16) * 4,
          (16 * 32 + 16) * 4 + 4,
        );
        await renderer.close();
        return pixels;
      }

      expect(await sample(depthTest: true, depthWrite: false), [
        0,
        255,
        0,
        255,
      ]);
      expect(await sample(depthTest: false, depthWrite: true), [
        255,
        0,
        0,
        255,
      ]);
    } finally {
      await owner.close();
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');

  test(
    'alpha ordering follows the camera and depth writes occlude later draws',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final camera = OrthographicCamera(
        left: -1,
        right: 1,
        top: 1,
        bottom: -1,
        near: .1,
        far: 10,
        position: const Vec3(0, 0, 3),
      );
      Future<List<int>> center(Scene scene) async {
        final image =
            ((await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: camera,
                        size: PhysicalSize(32, 32),
                      ),
                    ))
                    as ReadbackOutput)
                .image
                .pixels;
        return image.sublist((16 * 32 + 16) * 4, (16 * 32 + 16) * 4 + 4);
      }

      try {
        for (final path in ParticlePath.values) {
          final settings = ParticleSettings(
            capacity: 2,
            rate: 0,
            fixedStep: .1,
            lifetime: 1,
            gravity: Vec3.zero,
            path: path,
            space: ParticleSpace.world,
            size: ParticleCurve.constant(1),
            color: ParticleGradient(
              red: ParticleCurve([
                CurveKey(0, 0),
                CurveKey(.1, 1),
                CurveKey(1, 1),
              ]),
              green: ParticleCurve([
                CurveKey(0, 1),
                CurveKey(.1, 0),
                CurveKey(1, 0),
              ]),
              blue: ParticleCurve.constant(0),
              alpha: ParticleCurve.constant(.5),
            ),
          );
          final renderer = await ParticleRenderer.create(owner, settings);
          final scene = Scene()..background = const Color3(0, 0, 0);
          scene.add(renderer.mesh);
          final emitter = Group()..position = const Vec3(0, 0, .5);
          camera.position = const Vec3(0, 0, 3);
          camera.lookAt(Vec3.zero);
          await renderer.update(
            [const ParticleTick(1, 0, 1, .1)],
            emitter: emitter.localMatrix,
            camera: particleCameraTransform(camera),
          );
          emitter.position = const Vec3(0, 0, -.5);
          await renderer.update(
            [const ParticleTick(2, 1, 1, .1)],
            emitter: emitter.localMatrix,
            camera: particleCameraTransform(camera),
          );
          final front = await center(scene);
          expect(
            front[0],
            greaterThan(front[1]),
            reason: 'red is closer from +Z',
          );
          camera.position = const Vec3(0, 0, -3);
          camera.lookAt(Vec3.zero);
          await renderer.update(
            [],
            emitter: emitter.localMatrix,
            camera: particleCameraTransform(camera),
          );
          final back = await center(scene);
          expect(
            back[1],
            greaterThan(back[0]),
            reason: 'green is closer from -Z',
          );
          await renderer.close();
        }
        camera.position = const Vec3(0, 0, 3);
        camera.lookAt(Vec3.zero);
        for (final depthWrite in [false, true]) {
          final red = await ParticleRenderer.create(
            owner,
            ParticleSettings(
              capacity: 1,
              rate: 0,
              gravity: Vec3.zero,
              depthWrite: depthWrite,
              space: ParticleSpace.world,
              size: ParticleCurve.constant(1),
              color: ParticleGradient.solid(const Color3(1, 0, 0)),
            ),
          );
          final green = await ParticleRenderer.create(
            owner,
            ParticleSettings(
              capacity: 1,
              rate: 0,
              gravity: Vec3.zero,
              space: ParticleSpace.world,
              size: ParticleCurve.constant(1),
              color: ParticleGradient.solid(const Color3(0, 1, 0)),
            ),
          );
          final scene = Scene()..background = const Color3(0, 0, 0);
          scene.add(red.mesh).renderOrder = 0;
          scene.add(green.mesh).renderOrder = 1;
          await red.update(
            [ParticleTick(1, 0, 1, red.settings.fixedStep)],
            emitter: (Group()..position = const Vec3(0, 0, 1)).localMatrix,
            camera: particleCameraTransform(camera),
          );
          await green.update(
            [ParticleTick(1, 0, 1, green.settings.fixedStep)],
            emitter: Mat4.identity(),
            camera: particleCameraTransform(camera),
          );
          expect(
            await center(scene),
            depthWrite ? [255, 0, 0, 255] : [0, 255, 0, 255],
          );
          await red.close();
          await green.close();
        }
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
