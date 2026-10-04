import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'captured HDR probes publish atomically and select local materials',
    () async {
      final backend = await NativeBackend.create();
      final probes = await ReflectionProbes.create(backend);
      final resources = backend.createResourceScope();
      final captureScene = Scene()..ambient = 0;
      final room = captureScene.add(
        Mesh(
          BoxGeometry(width: 10, height: 10, depth: 10),
          StandardMaterial(
            baseColor: const Color3(0, 0, 0),
            emissive: const Color3(1, .5, .25),
            emissiveIntensity: 8,
          ),
        ),
      );
      final d = ReflectionProbeDescriptor(
        id: 0,
        position: Vec3.zero,
        bounds: Bounds3(const Vec3(-2, -2, -2), const Vec3(2, 2, 2)),
        faceSize: 16,
        quality: const EnvironmentQuality(
          specularWidth: 16,
          diffuseWidth: 16,
          brdfSize: 16,
          samples: 64,
        ),
      );
      try {
        final cycleClock = Stopwatch()..start();
        var captureCpuUs = 0;
        await probes.update(d, scene: captureScene, contentRevision: 1);
        for (var i = 0; i < 6; i++) {
          expect(probes.environment(0), isNull);
          await probes.advance();
          captureCpuUs += probes.lastCapture!.cpuSubmitTime.inMicroseconds;
        }
        expect(probes.captureFaces, 6);
        var steps = 6;
        while (probes.pending) {
          await probes.advance();
          expect(++steps, lessThan(20));
        }
        cycleClock.stop();
        final firstCycleUs = cycleClock.elapsedMicroseconds;
        expect(probes.revision(0), 1);
        final initial = probes.environment(0)!;
        final reader = resources.createChild();
        final pixels = ByteData.sublistView(
          await reader.readTexture(await reader.retain(initial.map.specular)),
        );
        await reader.close();
        expect(pixels.getUint16(0, Endian.little), closeTo(0x4800, 2));
        expect(pixels.getUint16(2, Endian.little), closeTo(0x4400, 2));
        final scene = Scene()
          ..ambient = 0
          ..reflectionProbes = probes
          ..background = const Color3(0, 0, 0);
        final mesh = scene.add(
          Mesh(
            PlaneGeometry(width: 4, height: 4),
            StandardMaterial(roughness: 1),
          ),
        );
        final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
        Future<int> draw() async =>
            ((await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: camera,
                        size: PhysicalSize(16, 16),
                        colorPipeline: ColorPipeline(
                          toneMapping: ToneMapping.reinhard,
                        ),
                      ),
                    ))
                    as ReadbackOutput)
                .image
                .pixels[(8 * 16 + 8) * 4];
        final local = await draw();
        mesh.material = StandardMaterial(roughness: 1, localReflections: false);
        final fallback = await draw();
        expect(local, greaterThan(fallback + 100));
        mesh.material = StandardMaterial(roughness: 1);
        await draw();
        room.material = StandardMaterial(
          baseColor: const Color3(0, 0, 0),
          emissive: const Color3(.25, 1, .5),
          emissiveIntensity: 4,
        );
        await probes.update(d, scene: captureScene, contentRevision: 2);
        await probes.advance();
        expect(identical(initial, probes.environment(0)), isTrue);
        await probes.cancel();
        expect(probes.revision(0), 1);
        final cancelledStart = probes.update(
          d,
          scene: captureScene,
          contentRevision: 99,
        );
        final rejectedStart = expectLater(cancelledStart, throwsStateError);
        await probes.cancel();
        await rejectedStart;
        expect(probes.pending, isFalse);
        expect(probes.revision(0), 1);
        await probes.update(d, scene: captureScene, contentRevision: 3);
        while (probes.pending) {
          await probes.advance();
        }
        expect(probes.revision(0), 3);
        expect(probes.retainedGenerations, 1);
        await draw();
        await probes.reclaim();
        expect(probes.retainedGenerations, 0);
        expect(identical(initial, probes.environment(0)), isFalse);
        expect(probes.select(const Vec3(3, 0, 0)), isNull);
        expect(
          probes.storageBytes,
          lessThanOrEqualTo(ReflectionProbes.maxStorageBytes),
        );
        for (var id = 1; id <= 3; id++) {
          await probes.update(
            ReflectionProbeDescriptor(
              id: id,
              position: Vec3(id == 1 ? .5 : -.5, 0, 0),
              priority: id == 3 ? 10 : 0,
              bounds: d.bounds,
              faceSize: 16,
              quality: d.quality,
            ),
            scene: captureScene,
            contentRevision: 1,
          );
          while (probes.pending) {
            await probes.advance();
          }
          if (id == 1) {
            expect(
              probes.select(const Vec3(.6, 0, 0)),
              same(probes.environment(1)),
            );
          }
        }
        expect(probes.count, 4);
        expect(
          probes.select(const Vec3(.6, 0, 0)),
          same(probes.environment(3)),
        );
        await expectLater(
          probes.update(
            ReflectionProbeDescriptor(
              id: 4,
              position: Vec3.zero,
              bounds: d.bounds,
            ),
            scene: captureScene,
            contentRevision: 1,
          ),
          throwsStateError,
        );
        print(
          'probe update: firstCycleUs=$firstCycleUs captureCpuUs=$captureCpuUs auxiliaryGpuUs=null first=$steps jobs, reused BRDF=${probes.completedJobs} jobs, local=$local fallback=$fallback, logical=${probes.storageBytes} bytes, capture attachments=${probes.lastCapture!.attachmentBytes} bytes',
        );
      } finally {
        await probes.close();
        await resources.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
